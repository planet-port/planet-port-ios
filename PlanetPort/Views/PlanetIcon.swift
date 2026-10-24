import SwiftUI

/// Planet 图标体系:动物矢量图标(Assets 中 animal-<key>,白色烧入 PDF)。
/// 图标 key 用户设置过则永久生效;否则按名称 djb2 哈希确定性选动物
/// (名称不变则图标不变,同名行星同图标)。底色自定义 hex 优先,
/// 否则按 id 哈希取 ThemeManager tint(已存在行星颜色不变)。
/// 官方行星与私有行星同规则,无特判。
enum PlanetIcon {
    /// 全部动物 key,与 Assets 中 animal-<key>.imageset 一一对应(92 个)。
    static let catalog: [String] = [
        "ant", "anteater", "armadillo", "badger", "bat", "beaver", "bee", "bird",
        "bison", "boar", "bug", "bull", "butterfly", "camel", "cat", "cobra",
        "cow", "crab", "crow", "deer", "dinosaur-rex", "dodo", "dog", "dolphin",
        "donkey", "dove", "dragon", "dragonfly", "duck", "eel", "elephant", "fish",
        "flamingo", "fox", "frog", "gecko", "goat", "goose", "gorilla", "hedgehog",
        "heron", "hippo", "horse", "hummingbird", "ibis", "jellyfish", "kangaroo",
        "kiwi-bird", "koala", "ladybug", "lion", "locust", "mammoth", "mole", "monkey",
        "mosquito", "octopus", "ostrich", "otter", "owl", "panda", "penguin", "pig",
        "piranha", "polar-bear", "rabbit", "rattlesnake", "raven", "rodent", "rooster",
        "scorpion", "seahorse", "seal", "shark", "sheep", "shrimp", "sloth", "snail",
        "snake", "sperm-whale", "spider", "squid", "squirrel", "swallow", "swan", "tiger",
        "tortoise", "turkey", "turtle", "unicorn", "vulture", "worm",
    ]

    /// 动物 key:有效自定义值永久生效;nil/旧值无效(SF Symbol 名)按名称哈希回退。
    static func animalKey(for planet: PlanetProfile) -> String {
        if let icon = planet.icon, catalog.contains(icon) { return icon }
        return catalog[djb2(of: planet.name) % catalog.count]
    }

    /// 图标资产名(animal- 前缀 imageset)。
    static func assetName(for planet: PlanetProfile) -> String {
        "animal-\(animalKey(for: planet))"
    }

    /// 底色:自定义 hex 优先(解析失败视为未设置),否则按 id 哈希回退 tint。
    static func tint(for planet: PlanetProfile) -> Color {
        if let hex = planet.iconColor, let color = Color(hex: hex) { return color }
        let tints = ThemeManager.shared.planetTints
        return tints[djb2(of: planet.id) % tints.count]
    }

    /// 随机底色 hex:随机色相 + 中低亮度域(饱和度 0.45–0.85、亮度 0.32–0.55),
    /// 白色图形对比度有保证。
    static func randomColorHex() -> String {
        hex(hue: .random(in: 0..<360),
            saturation: .random(in: 0.45...0.85),
            lightness: .random(in: 0.32...0.55))
    }

    /// 随机动物:优先排除本地化名与现有行星名相同的 key(名称建议与图标同源)。
    static func randomAnimal(excludingNames used: Set<String> = []) -> String {
        let candidates = catalog.filter { !used.contains(localizedName($0)) }
        return (candidates.isEmpty ? catalog : candidates).randomElement() ?? catalog[0]
    }

    /// 动物本地化名(animal.<key> 查表)。动态 key 须先拼 String 再构造
    /// LocalizationValue,避免字符串插值被当作格式化键。
    static func localizedName(_ key: String) -> String {
        loc(String.LocalizationValue("animal.\(key)"))
    }

    /// HSL → "#rrggbb"(小写)。h∈[0,360) s,l∈[0,1]。
    private static func hex(hue: Double, saturation: Double, lightness: Double) -> String {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = lightness - c / 2
        func channel(_ v: Double) -> Int {
            min(max(Int(((v + m) * 255).rounded()), 0), 255)
        }
        return String(format: "#%02x%02x%02x", channel(r1), channel(g1), channel(b1))
    }

    /// djb2 哈希:同一输入永远同一结果。
    private static func djb2(of string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash % 1_000_003)
    }
}

extension Color {
    /// "#RRGGBB" 解析;非法输入返回 nil。
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
