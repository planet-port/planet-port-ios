import Foundation
import NetworkExtension
import Combine
import UIKit

/// 全局 UI 状态：网络/Moon 列表 + 节点状态 + 隧道状态
/// 数据源：App Group 共享文件/UserDefaults + StatusStore Darwin 通知 + 定时查询
@MainActor
final class AppState: ObservableObject {
    /// "连接服务器"阶段（核心连行星根服务器）的超时阈值：到点仍未 online
    /// 判定物理网络故障，全部启用网络自动断开。
    static let connectTimeout: TimeInterval = 30

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
        let planetChanged = AppConfigStore.activatePlanet(planetId)
        activePlanetId = AppConfigStore.activePlanetId
        if planetChanged {
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
        networkStatuses = StatusStore.networkStatusesTyped
        networkConflicts = StatusStore.networkConflicts
        autoDisconnectConflictedNetworks()
        evaluateConnectTimer()
        if !nodeId.isEmpty { cacheNodeId(nodeId) }
    }

    /// 连接计时的起止与补偿判定：vpnRunning 且未 online 且有启用网络时起算；
    /// online 达成或 VPN 停止即取消。App 后台挂起时计时任务冻结，回前台后的
    /// 状态刷新走"已超期"分支补触发，不依赖计时器本身到点。
    private func evaluateConnectTimer() {
        if vpnRunning, !online,
           AppConfigStore.readActiveNetworks().contains(where: { $0.lastActivated }) {
            if let start = connectStartedAt {
                // 补触发：后台冻结错过到点，按已耗时直接判超时
                if Date().timeIntervalSince(start) >= Self.connectTimeout {
                    disconnectOnConnectTimeout()
                }
            } else {
                connectStartedAt = Date()
                connectTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    disconnectOnConnectTimeout()
                }
            }
        } else {
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            connectStartedAt = nil
        }
    }

    /// 连接超时自动断开：核心起跑超过 connectTimeout 仍未连通行星根服务器，
    /// 判定物理网络故障，当前行星全部启用网络关闭并记录原因（服务器连不上是
    /// 共享故障，单关一个无意义），Extension 随配置通知 leave；无剩余启用网络
    /// 则停 VPN。与冲突自动断开（autoDisconnectConflictedNetworks）同构。
    private func disconnectOnConnectTimeout() {
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
    private func autoDisconnectConflictedNetworks() {
        guard !networkConflicts.isEmpty else { return }
        var changed = false
        for (planetId, entries) in AppConfigStore.readNetworksByPlanet() {
            guard entries.contains(where: { $0.lastActivated && networkConflicts[$0.networkId] != nil }) else { continue }
            var updated = entries
            for index in updated.indices
            where updated[index].lastActivated && networkConflicts[updated[index].networkId] != nil {
                updated[index].lastConflict = networkConflicts[updated[index].networkId]
                updated[index].lastActivated = false
                changed = true
            }
            AppConfigStore.writeNetworks(updated, planetId: planetId)
        }
        if changed {
            reloadConfig()
            stopVPNIfNoActiveNetworks()
        }
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
                                self.networkStatuses = StatusStore.networkStatusesTyped
                            }
                        }
                    }
                    self.refreshActiveNetworkConfigs()
                } else {
                    self.networkConfigs = [:]
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
                        self.cacheNetworkName(entry.networkId, name)
                    }
                }
            }
        }
    }

    /// 网络名缓存：由连接后的 networkConfig 快照回填并持久化。
    private func cacheNetworkName(_ nwid: String, _ name: String) {
        var networks = AppConfigStore.readNetworks()
        guard let index = networks.firstIndex(where: { $0.networkId == nwid }) else { return }
        networks[index].networkName = name
        AppConfigStore.writeNetworks(networks)
        self.networks = networks
        self.planetNetworks = AppConfigStore.readNetworksByPlanet()
    }
}
