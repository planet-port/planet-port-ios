import Foundation

/// 多 Planet 文件导入。每份私有 Planet 独立保存，不会覆盖其它配置。
enum PlanetImporter {
    enum ImportError: LocalizedError {
        case badHeader
        case downloadFailed
        case emptyName

        var errorDescription: String? {
            switch self {
            case .badHeader: return loc("error.planet.badHeader")
            case .downloadFailed: return loc("error.downloadFailed")
            case .emptyName: return loc("error.planet.emptyName")
            }
        }
    }

    // MARK: - 名称保护（已隐藏）
    // /// 商标保护：名称不得包含 ZeroTier 及其变体（不区分大小写）。
    // /// "ZeroTier One"/"Zero Tier One" 分别被 "zerotier"/"zero tier" 前缀覆盖，无需单独列举。
    // static func containsReservedBrand(_ name: String) -> Bool {
    //     let lower = name.lowercased()
    //     return lower.contains("zerotier") || lower.contains("zero tier")
    // }

    @discardableResult
    static func importPlanetData(_ data: Data, name: String) throws -> PlanetProfile {
        guard data.first == 0x01 else { throw ImportError.badHeader }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw ImportError.emptyName }
        // guard !containsReservedBrand(normalizedName) else { throw ImportError.reservedName }

        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).planet"
        try FileManager.default.createDirectory(at: AppGroup.planetsDir,
                                                withIntermediateDirectories: true)
        try data.write(to: AppGroup.planetsDir.appendingPathComponent(fileName), options: .atomic)

        let profile = PlanetProfile(id: id, name: normalizedName, kind: .custom, fileName: fileName)
        var profiles = AppConfigStore.readPlanets()
        profiles.append(profile)
        AppConfigStore.writePlanets(profiles)
        return profile
    }

    static func importPlanetFromURL(_ urlString: String, name: String,
                                    completion: @escaping (Result<PlanetProfile, Error>) -> Void) {
        downloadPlanetFile(urlString) { result in
            switch result {
            case .success(let data):
                do {
                    completion(.success(try importPlanetData(data, name: name)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// 仅下载 Planet 文件内容，不校验、不落库（供"先就绪、后添加"的交互使用）。
    static func downloadPlanetFile(_ urlString: String,
                                   completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(ImportError.downloadFailed))
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        URLSession(configuration: config).dataTask(with: url) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(ImportError.downloadFailed))
                return
            }
            completion(.success(data))
        }.resume()
    }

    static func rename(_ profile: PlanetProfile, to name: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw ImportError.emptyName }
        // guard !containsReservedBrand(normalizedName) else { throw ImportError.reservedName }
        var profiles = AppConfigStore.readPlanets()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = normalizedName
        AppConfigStore.writePlanets(profiles)
    }

    /// 从 Planet 文件数据中提取 World ID（byte0 类型 + 8 字节大端）。
    static func worldId(of data: Data) -> UInt64? {
        guard data.count >= 9, data.first == 0x01 else { return nil }
        var id: UInt64 = 0
        for i in 1...8 { id = (id << 8) | UInt64(data[i]) }
        return id
    }

    /// 已存在的 World ID 集合（含官方 Planet 的内置 ID），用于添加时查重。
    static func existingWorldIds() -> Set<UInt64> {
        var ids: Set<UInt64> = [149604618] // ZT_WORLD_ID_EARTH
        for profile in AppConfigStore.readPlanets() {
            if let info = inspectPlanetFile(profile) {
                ids.insert(info.worldId)
            }
        }
        return ids
    }

    /// 更新自定义图标；nil 表示恢复自动生成。
    static func updateIcon(_ profile: PlanetProfile, to symbol: String?) throws {
        var profiles = AppConfigStore.readPlanets()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].icon = symbol
        AppConfigStore.writePlanets(profiles)
    }

    /// 从 .planet 文件尽力解读只读信息。
    /// 文件格式：byte0 类型(1=planet) + 8 字节大端 worldId + 8 字节大端时间戳。
    static func inspectPlanetFile(_ profile: PlanetProfile) -> (worldId: UInt64, timestamp: UInt64, fileSize: Int)? {
        guard let fileName = profile.fileName else { return nil }
        let url = AppGroup.planetsDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url), data.count >= 17, data[0] == 0x01 else { return nil }
        var worldId: UInt64 = 0
        var timestamp: UInt64 = 0
        for i in 1...8 { worldId = (worldId << 8) | UInt64(data[i]) }
        for i in 9...16 { timestamp = (timestamp << 8) | UInt64(data[i]) }
        return (worldId, timestamp, data.count)
    }
}
