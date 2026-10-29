import Foundation
import NetworkExtension
import Combine
import UIKit

/// 全局 UI 状态：网络/Moon 列表 + 节点状态 + 隧道状态
/// 数据源：App Group 共享文件/UserDefaults + StatusStore Darwin 通知 + 定时查询
@MainActor
final class AppState: ObservableObject {
    /// "连接服务器"阶段（核心连行星根服务器）的超时阈值：到点仍未 online
    /// 先复核，复核失败进入重试（见 connectRetryLimit），不直接判定故障。
    /// 全局设置可调（10~600 秒），默认 45；窗口起算时取值。
    static var connectTimeout: TimeInterval {
        let stored = AppGroup.defaults.double(forKey: AppGroup.prefConnectTimeout)
        guard stored > 0 else { return 45 }
        return min(max(stored, 10), 600)
    }
    /// 超时确认后到重启核心的重试间隔。
    static let connectRetryDelay: TimeInterval = 10
    /// 最大重试次数：超时后等 connectRetryDelay 重启核心重建 UDP 流（新源端口
    /// 可能赶上清洗放行窗口），累计满本次数仍失败才判定物理网络故障彻底断开。
    static let connectRetryLimit = 5

    @Published var planets: [PlanetProfile] = []
    @Published var selectedPlanetId: String = PlanetProfile.officialId
    @Published var activePlanetId: String = PlanetProfile.officialId
    /// 是否激活过任何 Planet：未激活过不显示"上次使用"角标。
    @Published var hasActivatedPlanet: Bool = false
    @Published var networks: [NetworkEntry] = []
    /// 各 Planet 各自的网络列表（首页分页并行渲染用，避免相邻页共享当前选中页数据）。
    @Published var planetNetworks: [String: [NetworkEntry]] = [:]
    /// 各行星下本机节点 ID 缓存（卡片与设置页离线显示用）。
    @Published var planetNodeIds: [String: String] = [:]
    @Published var moons: [MoonEntry] = []
    /// 各 Planet 关联的 moon 数量，供首页卡片展示。
    @Published var moonCounts: [String: Int] = [:]
    /// 各 Planet 的真实 World ID（16 位 hex），供卡片与设置页展示。
    @Published var planetWorldIds: [String: String] = [:]
    @Published var nodeId: String = ""
    @Published var online: Bool = false
    @Published var coreVersion: String = ""
    @Published var tunnelStatus: String = ""
    @Published var networkStatuses: [String: ZTNetworkStatus] = [:]
    /// 网络冲突（nwid → 原因原始码 "address"/"subnet"，文案在 UI 层生成）。
    @Published var networkConflicts: [String: String] = [:]
    @Published var networkConfigs: [String: NetworkConfigSnapshot] = [:]
    @Published var vpnRunning: Bool = false
    /// VPN 起跑（观察到 vpnRunning 且未 online）的时刻，卡片"连接服务器"
    /// 分段展示与超时判定的共同起点；online 达成或 VPN 停止时清空。
    @Published private(set) var connectStartedAt: Date?
    /// 连接超时任务（App 侧计时；后台挂起冻结，回前台经 evaluateConnectTimer 补触发）。
    private var connectTimeoutTask: Task<Void, Never>?
    /// 超时确认后的重试等待任务（connectRetryDelay 后重启核心）。
    private var connectRetryTask: Task<Void, Never>?
    /// 当前连接周期已重试次数（online 达成或周期结束即清零）。
    @Published private(set) var connectRetryCount = 0
    /// 首页自定义背景图（nil = 未设置，页面用纯底色）
    @Published var backgroundImage: UIImage? = BackgroundImageStore.load()

    /// 保存并应用新背景图（相册/URL 下载得到的数据统一走这里）
    func applyBackgroundImage(_ data: Data) throws {
        try BackgroundImageStore.save(data)
        backgroundImage = BackgroundImageStore.load()
    }

    /// 清除背景图
    func clearBackgroundImage() {
        BackgroundImageStore.clear()
        backgroundImage = nil
    }

    private var statusObserver: DarwinNotifyObserver?
    private var timer: AnyCancellable?
    /// World ID 解析结果缓存（key 为 planetId，value 为其 fileName），避免每次刷新重读 .planet 文件。
    private var worldIdCache: [String: String] = [:]
    private var worldIdCacheFiles: [String: String?] = [:]

    init() {
        reloadConfig()
        refreshStatus()
    }

    func startObserving() {
        resetStaleNetworksIfNeeded()
        statusObserver = StatusStore.observeChange { [weak self] in
            self?.refreshStatus()
            self?.reloadConfig()
        }
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pollRuntime() }
        pollRuntime()
    }

    /// 启动时若 VPN 未连接（含正在断开），之前标记为已连接的网络已实际离线，重置为断开，
    /// 避免列表继续显示"等待 VPN 连接"并在下次隧道启动时悄悄重新加入。
    private func resetStaleNetworksIfNeeded() {
        VPNManager.shared.connectionStatus { [weak self] status in
            let running = status == .connected || status == .connecting || status == .reasserting
            guard !running else { return }
            Task { @MainActor in
                AppConfigStore.resetAllNetworkActivation()
                self?.reloadConfig()
            }
        }
    }

    func reloadConfig() {
        planets = AppConfigStore.readPlanets()
        selectedPlanetId = AppConfigStore.selectedPlanetId
        activePlanetId = AppConfigStore.activePlanetId
        hasActivatedPlanet = AppConfigStore.hasActivatedPlanet
        stopVPNIfNoActiveNetworks()
        networks = AppConfigStore.readNetworks()
        planetNetworks = AppConfigStore.readNetworksByPlanet()
        planetNodeIds = Dictionary(uniqueKeysWithValues: planets.compactMap { profile in
            profile.lastNodeId.map { (profile.id, $0) }
        })
        moons = AppConfigStore.readMoons()
        // 一次读取 moons.json 按 planetId 分组统计，避免逐 Planet 重复读盘。
        let allMoons = AppConfigStore.readAllMoons()
        var counts = Dictionary(uniqueKeysWithValues: planets.map { ($0.id, 0) })
        for moon in allMoons {
            let key = moon.planetId ?? selectedPlanetId
            counts[key, default: 0] += 1
        }
        moonCounts = counts
        planetWorldIds = Dictionary(uniqueKeysWithValues: planets.map { profile -> (String, String) in
            if profile.kind == .official {
                // Core 内置官方 Planet，World ID 即 ZT_WORLD_ID_EARTH。
                return (profile.id, String(format: "%016llx", UInt64(149604618)))
            }
            if worldIdCacheFiles[profile.id] == profile.fileName, let cached = worldIdCache[profile.id] {
                return (profile.id, cached)
            }
            let value = PlanetImporter.inspectPlanetFile(profile)
                .map { String(format: "%016llx", $0.worldId) } ?? "—"
            worldIdCache[profile.id] = value
            worldIdCacheFiles[profile.id] = profile.fileName
            return (profile.id, value)
        })
    }

    var selectedPlanet: PlanetProfile {
        planets.first(where: { $0.id == selectedPlanetId }) ?? .official
    }

    var activePlanet: PlanetProfile {
        planets.first(where: { $0.id == activePlanetId }) ?? .official
    }

    /// 只切换首页浏览的配置，不触碰当前隧道。
    func selectPlanet(_ profile: PlanetProfile) {
        AppConfigStore.selectPlanet(profile.id)
        reloadConfig()
    }

    /// 用户主动打开网络时才应用 Planet（取网络归属的行星，而非当前浏览页，
    /// 避免滑页过程中的选中态错位导致激活错行星）；跨 Planet 时需要重启 Core。
    func applyPlanetAndStartVPN(_ planetId: String, completion: @escaping (Bool, String?) -> Void) {
        let previousPlanetId = activePlanetId
        let planetChanged = AppConfigStore.activatePlanet(planetId)
        activePlanetId = AppConfigStore.activePlanetId
        if planetChanged {
            // 行星切换数据对齐（一次性收敛，杜绝跨行星串显）：
            // 1) 旧行星网络启用标记清零——隧道已不再承载它们，残留会让旧行星
            //    卡片显示"建立隧道"等错态；lastConflict 保留（真实历史事件）。
            // 2) 共享状态区清空旧核心会话残留——networkStatuses 按 networkId
            //    全局索引且只在下次隧道启动时清，不清则切换窗口期跨行星串显
            //    "在线/请求配置"，online 同理。
            deactivateNetworks(planetId: previousPlanetId)
            reloadConfig()
            StatusStore.networkStatuses = [:]
            StatusStore.networkConflicts = [:]
            StatusStore.networkNames = [:]
            StatusStore.online = false
            StatusStore.postChange()
            online = false
            networkStatuses = [:]
            networkConfigs = [:]
            // 核心随行星切换重启，连接超时窗口重新起算
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            connectStartedAt = nil
        }
        VPNManager.shared.connectionStatus { status in
            let running = status == .connected || status == .connecting || status == .reasserting
            if planetChanged && running {
                VPNManager.shared.restart(completion: completion)
            } else if !running {
                VPNManager.shared.prepareAndStart(completion: completion)
            } else {
                completion(true, nil)
            }
        }
    }

    func refreshStatus() {
        nodeId = StatusStore.nodeId
        online = StatusStore.online
        coreVersion = StatusStore.coreVersion
        tunnelStatus = StatusStore.tunnelStatus
        // 状态/冲突按当前活跃行星的作用域读取：其它行星（含旧隧道会话）的同
        // networkId 状态天然隔离，不参与本行星的展示与判定
        networkStatuses = StatusStore.networkStatuses(planetId: activePlanetId)
        networkConflicts = StatusStore.networkConflicts(planetId: activePlanetId)
        syncNetworkNames()
        autoDisconnectConflictedNetworks()
        evaluateConnectTimer()
        if !nodeId.isEmpty { cacheNodeId(nodeId) }
    }

    /// 连接计时的起止与补偿判定：vpnRunning 且未 online 且有启用网络时起算；
    /// online 达成或 VPN 停止即取消。App 后台挂起时计时任务冻结，回前台后的
    /// 状态刷新走"已超期"分支补触发，不依赖计时器本身到点。
    private func evaluateConnectTimer() {
        // 重试等待期不起算新窗口：等 connectRetryDelay 重启核心后再由状态通知起算
        guard connectRetryTask == nil else { return }
        if vpnRunning, !online,
           AppConfigStore.readActiveNetworks().contains(where: { $0.lastActivated }) {
            if let start = connectStartedAt {
                // 补触发：后台冻结错过到点，按已耗时直接判超时
                if Date().timeIntervalSince(start) >= Self.connectTimeout {
                    disconnectOnConnectTimeout()
                }
            } else {
                connectStartedAt = Date()
                // 新连接周期开始：上一轮的超时断开记录随之失效（超时是整轮共享
                // 事件，不该在新周期里继续显示在未参与连接的网络上）
                clearStaleTimeoutRecords()
                connectTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    disconnectOnConnectTimeout()
                }
            }
        } else {
            // online 达成 / VPN 停止 / 全部断开：周期结束，重试状态一并清零
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            connectRetryTask?.cancel()
            connectRetryTask = nil
            connectRetryCount = 0
            connectStartedAt = nil
        }
    }

    /// 清除上一轮连接周期遗留的超时记录（仅 timeout；冲突记录是单网络事件，保留）。
    private func clearStaleTimeoutRecords() {
        let planetId = activePlanetId
        var updated = AppConfigStore.readNetworks(planetId: planetId)
        guard updated.contains(where: { $0.lastConflict == ConflictCode.timeout }) else { return }
        for index in updated.indices where updated[index].lastConflict == ConflictCode.timeout {
            updated[index].lastConflict = nil
        }
        AppConfigStore.writeNetworks(updated, planetId: planetId)
        reloadConfig()
    }

    /// 连接超时自动断开：核心起跑超过 connectTimeout 仍未连通行星根服务器，
    /// 判定物理网络故障，当前行星全部启用网络关闭并记录原因（服务器连不上是
    /// 共享故障，单关一个无意义），Extension 随配置通知 leave；无剩余启用网络
    /// 则停 VPN。与冲突自动断开（autoDisconnectConflictedNetworks）同构。
    private func disconnectOnConnectTimeout() {
        guard vpnRunning, !online else { return }
        // 断开前先向隧道进程复核实时 online：online 事件经 Darwin 通知送达有
        // 延迟，核心恰在超时边沿连上时不至于误杀（提示超时却连接成功）。
        VPNManager.shared.query(ProviderRequest(type: "status", nwid: nil)) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if reply?.online == true {
                    self.online = true
                    self.evaluateConnectTimer()
                    return
                }
                if self.connectRetryCount < Self.connectRetryLimit {
                    self.scheduleConnectRetry()
                } else {
                    self.performConnectTimeoutDisconnect()
                }
            }
        }
    }

    /// 超时确认后的核心重试：等 connectRetryDelay 重启核心（磁盘持久化身份与
    /// 配置，Extension 侧恢复 join；新源端口重建 UDP 流，间歇性清洗可赶上放行
    /// 窗口），重启的 online=false 通知到达后 evaluateConnectTimer 重新起算窗口。
    private func scheduleConnectRetry() {
        connectRetryCount += 1
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connectStartedAt = nil
        connectRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.connectRetryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            connectRetryTask = nil
            VPNManager.shared.query(ProviderRequest(type: "restartCore", nwid: nil)) { _ in }
        }
    }

    private func performConnectTimeoutDisconnect() {
        guard vpnRunning, !online else { return }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        connectStartedAt = nil
        let planetId = activePlanetId
        var updated = AppConfigStore.readNetworks(planetId: planetId)
        guard updated.contains(where: \.lastActivated) else { return }
        for index in updated.indices where updated[index].lastActivated {
            updated[index].lastActivated = false
            updated[index].lastConflict = ConflictCode.timeout
        }
        AppConfigStore.writeNetworks(updated, planetId: planetId)
        reloadConfig()
        stopVPNIfNoActiveNetworks()
    }

    /// 冲突自动断开：Extension 检出地址/网段冲突（原始码经 StatusStore 透出）后，
    /// App 侧立即停用后开启的网络并记录原因（lastConflict），Extension 随配置通知 leave。
    /// 数据面在 Extension 侧已隔离，此处收敛配置态；App 未运行时由下次启动补做。
    /// 冲突只可能来自隧道会话（= 活跃行星），限定活跃行星处理，避免其它行星
    /// 同 networkId 的网络被误关。
    private func autoDisconnectConflictedNetworks() {
        guard !networkConflicts.isEmpty else { return }
        let planetId = activePlanetId
        var updated = AppConfigStore.readNetworks(planetId: planetId)
        guard updated.contains(where: { $0.lastActivated && networkConflicts[$0.networkId] != nil }) else { return }
        var changed = false
        for index in updated.indices
        where updated[index].lastActivated && networkConflicts[updated[index].networkId] != nil {
            updated[index].lastConflict = networkConflicts[updated[index].networkId]
            updated[index].lastActivated = false
            changed = true
        }
        if changed {
            AppConfigStore.writeNetworks(updated, planetId: planetId)
            reloadConfig()
            stopVPNIfNoActiveNetworks()
        }
    }

    /// 旧行星网络停用：行星互斥（单隧道单行星），切换后旧行星的启用标记
    /// 是残留态，会让旧行星卡片显示"建立隧道"等错态。仅清启用标记，
    /// lastConflict 保留（单网络的真实历史事件）。
    private func deactivateNetworks(planetId: String) {
        var updated = AppConfigStore.readNetworks(planetId: planetId)
        guard updated.contains(where: \.lastActivated) else { return }
        for index in updated.indices where updated[index].lastActivated {
            updated[index].lastActivated = false
        }
        AppConfigStore.writeNetworks(updated, planetId: planetId)
    }

    /// 网络断开/删除后的收敛检查：活跃行星下已无启用网络时自动停掉 VPN，
    /// 避免隧道无网络空跑（冲突自动断开、删除网络、配置重载兜底统一走这里）。
    /// 按需连接也拦不住：stop() 内会先摘除 on-demand 规则再停隧道。
    func stopVPNIfNoActiveNetworks() {
        guard !AppConfigStore.readActiveNetworks().contains(where: { $0.lastActivated }) else { return }
        VPNManager.shared.stop()
    }

    /// 行星节点 ID 缓存：隧道在跑时读到即持久化到对应行星，离线后仍可显示。
    private func cacheNodeId(_ value: String) {
        guard !value.isEmpty else { return }
        var profiles = AppConfigStore.readPlanets()
        guard let index = profiles.firstIndex(where: { $0.id == activePlanetId }),
              profiles[index].lastNodeId != value else { return }
        profiles[index].lastNodeId = value
        AppConfigStore.writePlanets(profiles)
        planetNodeIds[activePlanetId] = value
    }

    /// 定时查询：隧道存活状态 + 节点在线（经 sendProviderMessage 走活进程）
    private func pollRuntime() {
        VPNManager.shared.connectionStatus { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.vpnRunning = (status == .connected || status == .connecting || status == .reasserting)
                self.evaluateConnectTimer()
                if self.vpnRunning {
                    VPNManager.shared.query(ProviderRequest(type: "status", nwid: nil)) { reply in
                        Task { @MainActor in
                            guard let reply else { return }
                            if let id = reply.nodeId, !id.isEmpty {
                                self.nodeId = id
                                self.cacheNodeId(id)
                            }
                            if let on = reply.online { self.online = on }
                            self.evaluateConnectTimer()
                            if let v = reply.coreVersion, !v.isEmpty { self.coreVersion = v }
                            if !self.networkStatuses.isEmpty || self.networks.contains(where: { $0.lastActivated }) {
                                self.networkStatuses = StatusStore.networkStatuses(planetId: self.activePlanetId)
                            }
                        }
                    }
                    self.refreshActiveNetworkConfigs()
                } else {
                    self.networkConfigs = [:]
                    // 隧道不在跑，状态快照整体失效（含旧会话残留），不参与展示
                    self.networkStatuses = [:]
                    self.networkConflicts = [:]
                }
            }
        }
    }

    private func refreshActiveNetworkConfigs() {
        let active = AppConfigStore.readActiveNetworks().filter(\.lastActivated)
        let activeIds = Set(active.map(\.networkId))
        networkConfigs = networkConfigs.filter { activeIds.contains($0.key) }
        for entry in active {
            VPNManager.shared.query(ProviderRequest(type: "networkConfig", nwid: entry.networkId)) { [weak self] reply in
                Task { @MainActor in
                    guard let self, let config = reply?.networkConfig else { return }
                    self.networkConfigs[entry.networkId] = config
                    // 首次连接拿到名称后写回缓存，之后离线也用缓存名显示。
                    let name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name != entry.networkName {
                        self.cacheNetworkName(entry.networkId, name, planetId: entry.planetId ?? self.activePlanetId)
                    }
                }
            }
        }
    }

    /// 名称事件回填：Extension 随状态通知透出的控制器名称（见 StatusStore.networkNames）
    /// 与本地缓存比对，仅差异时落盘——连接/改名后的首个 netconf 回调即刻生效，
    /// 不等 5s 轮询反查。
    private func syncNetworkNames() {
        let names = StatusStore.networkNames(planetId: activePlanetId)
        guard !names.isEmpty else { return }
        var updated = AppConfigStore.readNetworks(planetId: activePlanetId)
        var changed = false
        for index in updated.indices {
            guard let name = names[updated[index].networkId],
                  !name.isEmpty, name != updated[index].networkName else { continue }
            updated[index].networkName = name
            changed = true
        }
        if changed {
            AppConfigStore.writeNetworks(updated, planetId: activePlanetId)
            if activePlanetId == selectedPlanetId { self.networks = updated }
            self.planetNetworks = AppConfigStore.readNetworksByPlanet()
        }
    }

    /// 网络名缓存：由连接后的 networkConfig 快照回填并持久化。
    /// 写回网络归属的行星（调用方轮询遍历的是 active 行星网络，缺省 selected
    /// 行星在滑页场景下错位，firstIndex 落空导致名称永不回填）。
    private func cacheNetworkName(_ nwid: String, _ name: String, planetId: String) {
        var networks = AppConfigStore.readNetworks(planetId: planetId)
        guard let index = networks.firstIndex(where: { $0.networkId == nwid }) else { return }
        // 闭包捕获的 entry 是轮询开始时的快照：事件路径（syncNetworkNames）可能
        // 已先写盘同名，此处按最新文件内容早退，避免冗余写盘与 Extension 空跑
        guard networks[index].networkName != name else { return }
        networks[index].networkName = name
        AppConfigStore.writeNetworks(networks, planetId: planetId)
        if planetId == selectedPlanetId { self.networks = networks }
        self.planetNetworks = AppConfigStore.readNetworksByPlanet()
    }
}
