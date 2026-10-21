import Foundation

enum AppGroup {
    static let id = "group.cn.imgozi.planetport"
    static var container: URL {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return shared
        }
        // 未签名模拟器/SwiftUI Preview 没有 App Group entitlement，使用应用沙盒兜底。
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("PlanetPort-AppGroup", isDirectory: true)
    }
    static var defaults: UserDefaults {
        UserDefaults(suiteName: id) ?? .standard
    }
    /// 核心状态文件根目录（identity.*、planet、moons.d/ 等）
    static var datastore: URL { container.appendingPathComponent("datastore", isDirectory: true) }
    static var configDir: URL { container.appendingPathComponent("config", isDirectory: true) }
    static var planetsDir: URL { datastore.appendingPathComponent("planets", isDirectory: true) }
    static func planetStateDir(_ planetId: String) -> URL {
        datastore.appendingPathComponent("planet-state", isDirectory: true)
            .appendingPathComponent(planetId, isDirectory: true)
    }

    // MARK: - 偏好 key（对齐 Android Constants.java）
    static let prefUseCustomPlanet = "planet_use_custom"
    /// 首页当前正在浏览的 Planet。切换它不会立即影响隧道。
    static let prefSelectedPlanetId = "planet_selected_id"
    /// Packet Tunnel 当前实际使用的 Planet。
    static let prefActivePlanetId = "planet_active_id"
    /// 当前私有 Planet 文件名，供 Objective-C++ DataStore hook 直接读取。
    static let prefActivePlanetFile = "planet_active_file"
    static let prefAllowCellular = "network_use_cellular_data"
    static let prefDisableIPv6 = "network_disable_ipv6"
    static let prefConnectOnDemand = "general_connect_on_demand"
    /// 首页左右屏幕边缘滑动切换 Planet。
    static let prefEdgeSwipePlanet = "interaction_edge_swipe_planet"
}
