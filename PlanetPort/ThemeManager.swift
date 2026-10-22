import SwiftUI

/// 全局主题：用户只设一个主色，明暗变体、状态色派生、行星装饰盘全部运行时计算。
/// 视图在 body 内访问本类属性即建立观察（@Observable 动态追踪），改色即时生效。
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    /// 预设主色板：默认红（三角配色定稿 #D44037）+ 7 个国画经典色。
    static let presets: [UInt32] = [
        0xD44037,  // 默认红
        0xFFB61E,  // 藤黄
        0x789262,  // 竹青
        0x57C3C2,  // 石绿
        0x4C8DAE,  // 群青
        0x003472,  // 花青
        0x4A4266,  // 黛
        0x9D2933,  // 胭脂
    ]
    static let presetNames = ["默认红", "藤黄", "竹青", "石绿", "群青", "花青", "黛", "胭脂"]

    private static let keyMain = "theme.mainColorHex"
    private static let keyDerive = "theme.deriveStatusColor"

    private(set) var mainHex: UInt32
    private(set) var deriveStatusColor: Bool

    private init() {
        let defaults = UserDefaults.standard
        mainHex = defaults.object(forKey: Self.keyMain) == nil
            ? 0xD44037 : UInt32(defaults.integer(forKey: Self.keyMain))
        deriveStatusColor = defaults.bool(forKey: Self.keyDerive)
    }

    func setMainColor(_ hex: UInt32) {
        mainHex = hex
        UserDefaults.standard.set(Int(hex), forKey: Self.keyMain)
    }

    func setDeriveStatusColor(_ on: Bool) {
        deriveStatusColor = on
        UserDefaults.standard.set(on, forKey: Self.keyDerive)
    }

    // MARK: - 派生色

    /// 全局主色：浅色用原色，深色提亮度增饱和（对齐色盘 500/200 明暗分级手法）。
    var accent: Color {
        let base = Self.hsl(mainHex)
        return Self.dynamic(
            light: Self.color(HSL(h: base.h, s: base.s, l: base.l)),
            dark: Self.color(HSL(h: base.h, s: min(1, base.s + 0.2), l: min(0.72, base.l + 0.14))))
    }

    /// 成功/在线状态色：默认固定 A 系绿资产；开关打开时随主色 +120° 三角派生。
    var success: Color {
        guard deriveStatusColor else { return Color("SuccessGreen") }
        let base = Self.hsl(mainHex)
        let h = (base.h + 120).truncatingRemainder(dividingBy: 360)
        return Self.dynamic(
            light: Self.color(HSL(h: h, s: max(0.6, base.s), l: 0.32)),
            dark: Self.color(HSL(h: h, s: max(0.5, base.s * 0.8), l: 0.45)))
    }

    /// 行星装饰盘：主色 ±120° 三角的 500/200 档 + 两档深色，共 8 色。
    var planetTints: [Color] {
        let base = Self.hsl(mainHex)
        let hues = [
            base.h,
            (base.h + 120).truncatingRemainder(dividingBy: 360),
            (base.h + 240).truncatingRemainder(dividingBy: 360),
        ]
        var colors: [Color] = []
        for h in hues { colors.append(Self.color(HSL(h: h, s: 0.65, l: 0.52))) }
        for h in hues { colors.append(Self.color(HSL(h: h, s: 0.55, l: 0.68))) }
        colors.append(Self.color(HSL(h: hues[1], s: 0.7, l: 0.32)))
        colors.append(Self.color(HSL(h: hues[2], s: 0.7, l: 0.32)))
        return colors
    }

    // MARK: - 色彩换算（供设置页拾色器与色板）

    static func color(hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    static func hex(of color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return (channel(r) << 16) | (channel(g) << 8) | channel(b)
    }

    // MARK: - 色彩数学（HSL）

    private struct HSL { var h: Double; var s: Double; var l: Double }  // h: 0..<360

    private static func color(_ hsl: HSL) -> Color {
        let rgb = hslToRgb(hsl)
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    /// 明暗双版本色（UIColor dynamic provider）。
    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    private static func hsl(_ hex: UInt32) -> HSL {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return HSL(h: 0, s: 0, l: l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        let h: Double
        if maxC == r {
            h = ((g - b) / d + (g < b ? 6 : 0)) * 60
        } else if maxC == g {
            h = ((b - r) / d + 2) * 60
        } else {
            h = ((r - g) / d + 4) * 60
        }
        return HSL(h: h, s: s, l: l)
    }

    private static func hslToRgb(_ hsl: HSL) -> (Double, Double, Double) {
        let h = hsl.h / 60
        let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.l - c / 2
        let rgb: (Double, Double, Double)
        switch h {
        case ..<1: rgb = (c, x, 0)
        case ..<2: rgb = (x, c, 0)
        case ..<3: rgb = (0, c, x)
        case ..<4: rgb = (0, x, c)
        case ..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }
}
