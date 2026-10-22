import Foundation
import NetworkExtension
import Combine

/// 全局 UI 状态：网络/Moon 列表 + 节点状态 + 隧道状态
/// 数据源：App Group 共享文件/UserDefaults + StatusStore Darwin 通知 + 定时查询
@MainActor
final class AppState: ObservableObject {
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
    @Published var networkStatuses: [String: String] = [:]
    @Published var networkConfigs: [String: NetworkConfigSnapshot] = [:]
    @Published var vpnRunning: Bool = false

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

    /// 用户主动打开网络时才应用所选 Planet；跨 Planet 时需要重启 Core。
    func applySelectedPlanetAndStartVPN(completion: @escaping (Bool, String?) -> Void) {
        let planetChanged = AppConfigStore.activatePlanet(selectedPlanetId)
        activePlanetId = AppConfigStore.activePlanetId
        if planetChanged {
            online = false
            networkStatuses = [:]
            networkConfigs = [:]
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
        networkStatuses = StatusStore.networkStatuses
        if !nodeId.isEmpty { cacheNodeId(nodeId) }
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
                if self.vpnRunning {
                    VPNManager.shared.query(ProviderRequest(type: "status", nwid: nil)) { reply in
                        Task { @MainActor in
                            guard let reply else { return }
                            if let id = reply.nodeId, !id.isEmpty {
                                self.nodeId = id
                                self.cacheNodeId(id)
                            }
                            if let on = reply.online { self.online = on }
                            if let v = reply.coreVersion, !v.isEmpty { self.coreVersion = v }
                            if !self.networkStatuses.isEmpty || self.networks.contains(where: { $0.lastActivated }) {
                                self.networkStatuses = StatusStore.networkStatuses
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
