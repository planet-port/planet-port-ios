import SwiftUI

@main
struct PlanetPortApp: App {
    // 单例引用上建立观察：主题/语言变更时驱使整个 WindowGroup 重算。
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var language = LanguageManager.shared

    init() {
        // 标题栏全局全透明：无底色无毛玻璃（含滚动边缘态），仅保留标题与返回键。
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactAppearance = nav
        bar.compactScrollEdgeAppearance = nav

        // QR 渲染管线预热：CIQRCodeGenerator/CIContext 进程内首次调用有
        // 数百毫秒一次性初始化（着色器编译等），启动时后台付掉这笔代价，
        // 避免冷启动后首次分享的编码/渲染被拖慢。
        Task.detached(priority: .utility) { _ = QRRender.generate("warmup") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 全局主色由 ThemeManager 运行时派生（浅色原色/深色提亮）。
                .tint(ThemeManager.shared.accent)
                // 语言覆盖：用户在设置页指定后驱动 SwiftUI 文案查表（读取 locale
                // 属性建立观察，切换即时生效）；String 上下文走 loc() 同步覆盖。
                .environment(\.locale, LanguageManager.shared.locale)
        }
    }
}
