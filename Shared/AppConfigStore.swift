import Foundation

enum AppConfigStore {
    static let configChangedNotification = "cn.imgozi.PlanetPortI.configChanged"

    private static let networksFile = AppGroup.configDir.appendingPathComponent("networks.json")
    private static let moonsFile = AppGroup.configDir.appendingPathComponent("moons.json")
    private static let planetsFile = AppGroup.configDir.appendingPathComponent("planets.json")

    // MARK: - Planet

    static func readPlanets() -> [PlanetProfile] {
        bootstrapIfNeeded()
        let profiles: [PlanetProfile] = read(planetsFile) ?? []
        return profiles.isEmpty ? [.official] : profiles
    }

    static func writePlanets(_ profiles: [PlanetProfile]) {
        let normalized = profiles.contains(where: { $0.id == PlanetProfile.officialId })
            ? profiles
            : [.official] + profiles
        write(normalized, planetsFile)
    }

    static var selectedPlanetId: String {
        bootstrapIfNeeded()
        let stored = AppGroup.defaults.string(forKey: AppGroup.prefSelectedPlanetId)
        let profiles: [PlanetProfile] = read(planetsFile) ?? []
        return profiles.contains(where: { $0.id == stored }) ? stored! : PlanetProfile.officialId
    }

    static var activePlanetId: String {
        bootstrapIfNeeded()
        let stored = AppGroup.defaults.string(forKey: AppGroup.prefActivePlanetId)
        let profiles: [PlanetProfile] = read(planetsFile) ?? []
        return profiles.contains(where: { $0.id == stored }) ? stored! : PlanetProfile.officialId
    }

    /// 是否激活过任何 Planet（首次安装前从未开过隧道）。activePlanetId 在
    /// 未激活时也回退 officialId 用于显示，角标等"用过"语义须以此区分。
    static var hasActivatedPlanet: Bool {
        AppGroup.defaults.string(forKey: AppGroup.prefActivePlanetId) != nil
    }

    /// 只改变首页浏览上下文，不通知、更不重启隧道。
    static func selectPlanet(_ id: String) {
        guard readPlanets().contains(where: { $0.id == id }) else { return }
        AppGroup.defaults.set(id, forKey: AppGroup.prefSelectedPlanetId)
    }

    /// 设置 Packet Tunnel 下次启动要加载的 Planet。调用方负责按需重启/启动 VPN。
    @discardableResult
    static func activatePlanet(_ id: String) -> Bool {
        guard let profile = readPlanets().first(where: { $0.id == id }) else { return false }
        let changed = activePlanetId != id
        AppGroup.defaults.set(id, forKey: AppGroup.prefActivePlanetId)
        AppGroup.defaults.set(profile.kind == .custom, forKey: AppGroup.prefUseCustomPlanet)
        if let fileName = profile.fileName {
            AppGroup.defaults.set(fileName, forKey: AppGroup.prefActivePlanetFile)
        } else {
            AppGroup.defaults.removeObject(forKey: AppGroup.prefActivePlanetFile)
        }
        return changed
    }

    /// 删除私有 Planet 及其 Network/Moon。若它正在生效，回退到官方配置。
    static func deletePlanet(_ profile: PlanetProfile) {
        guard profile.kind == .custom else { return }
        let wasSelected = selectedPlanetId == profile.id
        let wasActive = activePlanetId == profile.id
        var profiles = readPlanets()
        profiles.removeAll { $0.id == profile.id }
        writePlanets(profiles)

        var networks: [NetworkEntry] = read(networksFile) ?? []
        networks.removeAll { $0.planetId == profile.id }
        write(networks, networksFile)

        var moons: [MoonEntry] = read(moonsFile) ?? []
        moons.removeAll { $0.planetId == profile.id }
        write(moons, moonsFile)

        if let fileName = profile.fileName {
            try? FileManager.default.removeItem(at: AppGroup.planetsDir.appendingPathComponent(fileName))
        }
        try? FileManager.default.removeItem(at: AppGroup.planetStateDir(profile.id))
        if wasSelected { selectPlanet(PlanetProfile.officialId) }
        if wasActive { activatePlanet(PlanetProfile.officialId) }
        notifyConfigChanged()
    }

    // MARK: - 当前 Planet 下的 Network / Moon

    static func readNetworks(planetId: String? = nil) -> [NetworkEntry] {
        bootstrapIfNeeded()
        let id = planetId ?? selectedPlanetId
        let all: [NetworkEntry] = read(networksFile) ?? []
        return all.filter { $0.planetId == id }
    }

    /// 一次读盘，按 Planet 分组返回全部网络（供首页各分页并行渲染各自数据）。
    static func readNetworksByPlanet() -> [String: [NetworkEntry]] {
        bootstrapIfNeeded()
        let all: [NetworkEntry] = read(networksFile) ?? []
        return Dictionary(grouping: all.filter { $0.planetId != nil }, by: { $0.planetId! })
    }

    static func readActiveNetworks() -> [NetworkEntry] {
        readNetworks(planetId: activePlanetId)
    }

    static func writeNetworks(_ values: [NetworkEntry], planetId: String? = nil) {
        let id = planetId ?? selectedPlanetId
        var all: [NetworkEntry] = read(networksFile) ?? []
        all.removeAll { $0.planetId == id }
        all.append(contentsOf: values.map {
            var value = $0
            value.planetId = id
            return value
        })
        write(all, networksFile)
        notifyConfigChanged()
    }

    static func readMoons(planetId: String? = nil) -> [MoonEntry] {
        bootstrapIfNeeded()
        let id = planetId ?? selectedPlanetId
        return readAllMoons().filter { $0.planetId == id }
    }

    /// 全量读取 moons.json（跨 Planet 统计时使用，只读一次盘）。
    static func readAllMoons() -> [MoonEntry] {
        bootstrapIfNeeded()
        return read(moonsFile) ?? []
    }

    static func readActiveMoons() -> [MoonEntry] {
        readMoons(planetId: activePlanetId)
    }

    static func writeMoons(_ values: [MoonEntry], planetId: String? = nil) {
        let id = planetId ?? selectedPlanetId
        var all: [MoonEntry] = read(moonsFile) ?? []
        all.removeAll { $0.planetId == id }
        all.append(contentsOf: values.map {
            var value = $0
            value.planetId = id
            return value
        })
        write(all, moonsFile)
        notifyConfigChanged()
    }

    /// 应用启动且 VPN 未连接时，所有 Planet 下标记为已连接的网络一律视为已断开。
    /// 静默写文件（不 notifyConfigChanged）：隧道未运行，无 Extension 需要通知。
    static func resetAllNetworkActivation() {
        bootstrapIfNeeded()
        guard var all: [NetworkEntry] = read(networksFile),
              all.contains(where: { $0.lastActivated }) else { return }
        for index in all.indices { all[index].lastActivated = false }
        write(all, networksFile)
    }

    // MARK: - 首次升级迁移

    private static func bootstrapIfNeeded() {
        if !FileManager.default.fileExists(atPath: planetsFile.path) {
            var profiles: [PlanetProfile] = [.official]
            var migrationTarget = PlanetProfile.officialId
            let legacyURL = AppGroup.datastore.appendingPathComponent("planet.custom")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                let legacy = PlanetProfile(id: "legacy-custom", name: "自定义 Planet",
                                           kind: .custom, fileName: "legacy-custom.planet")
                profiles.append(legacy)
                try? FileManager.default.createDirectory(at: AppGroup.planetsDir,
                                                         withIntermediateDirectories: true)
                let target = AppGroup.planetsDir.appendingPathComponent("legacy-custom.planet")
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.copyItem(at: legacyURL, to: target)
                }
                if AppGroup.defaults.bool(forKey: AppGroup.prefUseCustomPlanet) {
                    migrationTarget = legacy.id
                }
            }
            write(profiles, planetsFile)
            AppGroup.defaults.set(migrationTarget, forKey: AppGroup.prefSelectedPlanetId)
            AppGroup.defaults.set(migrationTarget, forKey: AppGroup.prefActivePlanetId)
            if let profile = profiles.first(where: { $0.id == migrationTarget }),
               let fileName = profile.fileName {
                AppGroup.defaults.set(fileName, forKey: AppGroup.prefActivePlanetFile)
            }
            migrateLegacyCoreState(to: migrationTarget)
        }

        let fallback = AppGroup.defaults.string(forKey: AppGroup.prefSelectedPlanetId)
            ?? AppGroup.defaults.string(forKey: AppGroup.prefActivePlanetId)
            ?? PlanetProfile.officialId
        var networks: [NetworkEntry] = read(networksFile) ?? []
        if networks.contains(where: { $0.planetId == nil }) {
            networks = networks.map {
                var value = $0
                if value.planetId == nil { value.planetId = fallback }
                return value
            }
            write(networks, networksFile)
        }
        var moons: [MoonEntry] = read(moonsFile) ?? []
        if moons.contains(where: { $0.planetId == nil }) {
            moons = moons.map {
                var value = $0
                if value.planetId == nil { value.planetId = fallback }
                return value
            }
            write(moons, moonsFile)
        }
    }

    /// 旧版 Core 缓存没有 Planet 维度；升级时归入此前实际生效的 Planet。
    private static func migrateLegacyCoreState(to planetId: String) {
        let destinationRoot = AppGroup.planetStateDir(planetId)
        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for directory in ["moons.d", "peers.d", "networks.d"] {
            let source = AppGroup.datastore.appendingPathComponent(directory, isDirectory: true)
            let destination = destinationRoot.appendingPathComponent(directory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 配置变更后通知 extension 重读。
    static func notifyConfigChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(configChangedNotification as CFString), nil, nil, true)
    }
}
