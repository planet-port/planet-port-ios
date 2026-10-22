import SwiftUI

/// Planet 图标：自定义 SF Symbol 优先，否则按 id 确定性哈希自动生成。
enum PlanetIcon {
    /// 精选符号集，避免依赖较新系统的符号名。
    static let catalog: [String] = [
        "globe", "network", "globe.asia.australia.fill", "sphere",
        "hexagon.fill", "circle.hexagongrid.fill", "cloud.fill", "server.rack",
        "antenna.radiowaves.left.and.right", "dot.circle.and.cursorarrow",
        "shareplay", "seal.fill",
    ]
    /// 装饰盘随全局主色三角派生（ThemeManager），白色符号对比度按 500/200/深档选取。
    static func symbol(for planet: PlanetProfile) -> String {
        planet.icon ?? catalog[hashIndex(of: planet) % catalog.count]
    }

    static func tint(for planet: PlanetProfile) -> Color {
        let tints = ThemeManager.shared.planetTints
        return tints[hashIndex(of: planet) % tints.count]
    }

    /// djb2 哈希，保证同一 Planet 永远生成同一图标。
    private static func hashIndex(of planet: PlanetProfile) -> Int {
        var hash: UInt64 = 5381
        for byte in planet.id.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % UInt64(catalog.count))
    }
}
