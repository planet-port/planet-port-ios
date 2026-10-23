import Foundation
import Observation

/// 应用语言：默认跟随系统，用户在设置页指定后全局覆盖（App 与 Tunnel 共读）。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en

    var id: String { rawValue }

    /// 各语言选项以自身名称显示（不随界面语言变化）；nil = "跟随系统"走本地化文案。
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        }
    }
}

/// 全局语言状态：视图在 body 内访问 locale 即建立观察，切换即时生效。
@Observable
final class LanguageManager {
    static let shared = LanguageManager()

    private(set) var current: AppLanguage

    private init() {
        current = AppLanguage(rawValue: AppGroup.defaults.string(forKey: AppGroup.prefLanguage) ?? "")
            ?? .system
    }

    var locale: Locale {
        switch current {
        case .system: return Locale.current
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .en: return Locale(identifier: "en")
        }
    }

    func set(_ language: AppLanguage) {
        current = language
        AppGroup.defaults.set(language.rawValue, forKey: AppGroup.prefLanguage)
    }
}

/// 按当前应用语言查表（用户未指定时回退系统语言）。
/// 与 SwiftUI Text 的 .environment(\.locale) 覆盖配套，保证 String 上下文
/// （错误消息、状态文案）与界面文案使用同一语言。
func loc(_ value: String.LocalizationValue) -> String {
    var resource = LocalizedStringResource(value)
    if LanguageManager.shared.current != .system {
        resource.locale = LanguageManager.shared.locale
    }
    return String(localized: resource)
}

/// 文件大小统一使用 KB/MB 等国际单位（不随语言本地化），规避
/// ByteCountFormatter 跟系统语言导致的单位翻译问题。
/// 分级与 ByteCountFormatter .file 风格一致（十进制，KB=1000）。
func locFileSize(_ bytes: Int) -> String {
    let units: [(Double, String)] = [
        (1_000_000_000_000, "TB"),
        (1_000_000_000, "GB"),
        (1_000_000, "MB"),
        (1_000, "KB"),
    ]
    let value = Double(bytes)
    for (factor, unit) in units where value >= factor {
        return String(format: "%.1f %@", value / factor, unit)
    }
    return "\(bytes) B"
}
