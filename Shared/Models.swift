import Foundation

enum DNSMode: String, Codable {
    case none, network, custom
}

enum PlanetKind: String, Codable {
    case official
    case custom
}

/// ZT_VirtualNetworkStatus（Core/include/ZeroTierOne.h，0..6）。
/// 跨进程契约（Extension → App）：StatusStore 与 ProviderReply 传原始枚举值，
/// 中文文案仅在展示层通过 displayName 生成——禁止用文案字符串做逻辑判断。
/// 核心未来新增状态码统一落 .unknown（兜底文案"未知"），两条读取路径行为一致。
enum ZTNetworkStatus: Int, Codable {
    case requestingConfiguration = 0   // REQUESTING_CONFIGURATION
    case ok = 1                        // OK
    case accessDenied = 2              // ACCESS_DENIED
    case notFound = 3                  // NOT_FOUND
    case portError = 4                 // PORT_ERROR
    case clientTooOld = 5              // CLIENT_TOO_OLD
    case authRequired = 6              // AUTHENTICATION_REQUIRED
    /// 核心报出的未来新增状态码（不在 0..6）。
    case unknown = -1

    init(coreStatus: Int32) {
        self = ZTNetworkStatus(rawValue: Int(coreStatus)) ?? .unknown
    }

    /// 展示文案（仅 UI 层使用）
    var displayName: String {
        switch self {
        case .requestingConfiguration: return loc("network.status.requestingConfiguration")
        case .ok: return loc("network.status.ok")
        case .accessDenied: return loc("network.status.accessDenied")
        case .notFound: return loc("network.status.notFound")
        case .portError: return loc("network.status.portError")
        case .clientTooOld: return loc("network.status.clientTooOld")
        case .authRequired: return loc("network.status.authRequired")
        case .unknown: return loc("network.status.unknown")
        }
    }

    /// 首次加入待控制器授权：核心报"需要认证"或"拒绝访问"均属正常流程。
    var isPendingAuthorization: Bool {
        self == .authRequired || self == .accessDenied
    }

    /// 需要弹窗提醒用户的异常（待授权不算，状态行显示即可）。
    var isAlertable: Bool {
        self == .notFound || self == .portError || self == .clientTooOld
    }
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

    /// UI 展示名：官方行星的存储名不翻译，展示时映射为本地化文案。
    var displayName: String {
        id == PlanetProfile.officialId ? loc("planet.official.name") : name
    }
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
    /// 最近一次冲突原因原始码（"address"/"subnet"）：冲突自动断开时记录，
    /// 卡片显示「地址/网段冲突,断开」；再次手动开启时清除。nil = 无冲突记录。
    var lastConflict: String? = nil
}

struct MoonEntry: Codable, Identifiable, Equatable {
    var id: String { String(format: "%016llx", worldId) }
    var worldId: UInt64
    var seed: UInt64
    var fromFile: Bool
    /// nil 仅用于兼容升级前的数据。
    var planetId: String? = nil

    /// moons.d 缓存文件路径
    var cacheFileURL: URL {
        AppGroup.planetStateDir(planetId ?? AppConfigStore.selectedPlanetId)
            .appendingPathComponent("moons.d", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.moon", worldId))
    }
}
