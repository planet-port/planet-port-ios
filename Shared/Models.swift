import Foundation

enum DNSMode: String, Codable {
    case none, network, custom
}

enum PlanetKind: String, Codable {
    case official
    case custom
}

/// 一套可独立切换的 Planet 配置。Network 与 Moon 均通过 planetId 归属于它。
struct PlanetProfile: Codable, Identifiable, Equatable {
    static let officialId = "official"
    static let official = PlanetProfile(id: officialId, name: "ZeroTier 官方",
                                        kind: .official, fileName: nil)

    var id: String
    var name: String
    var kind: PlanetKind
    /// 私有 Planet 在 datastore/planets 下的文件名；官方 Planet 使用 Core 内置文件。
    var fileName: String?
    /// 自定义 SF Symbol 图标名；nil 时按 id 哈希自动生成。
    var icon: String? = nil
    /// 该行星下本机节点 ID 的缓存（隧道运行时回读并持久化，离线可显示）。
    var lastNodeId: String? = nil
}

struct NetworkEntry: Codable, Identifiable, Equatable {
    var id: String { networkId }
    var networkId: String      // 16 位 hex
    var networkName: String
    var lastActivated: Bool
    var routeViaZeroTier: Bool
    var dnsMode: DNSMode
    var customDns: [String]
    /// nil 仅用于兼容升级前的数据，首次读取时会迁移到当时选中的 Planet。
    var planetId: String? = nil
}

struct MoonEntry: Codable, Identifiable, Equatable {
    var id: String { String(format: "%016llx", worldId) }
    var worldId: UInt64
    var seed: UInt64
    var fromFile: Bool
    /// nil 仅用于兼容升级前的数据。
    var planetId: String? = nil

    /// moons.d 缓存文件路径（对齐 Android MoonOrbit.MOON_FILE_PATH）
    var cacheFileURL: URL {
        AppGroup.planetStateDir(planetId ?? AppConfigStore.selectedPlanetId)
            .appendingPathComponent("moons.d", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.moon", worldId))
    }
}
