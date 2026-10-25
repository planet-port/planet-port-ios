import SwiftUI

@main
struct PlanetPortApp: App {
    init() {
        // 偏好默认值：未写入过时按"允许移动数据"处理（HomeView 的 bool 判断与
        // PrefsView 的 AppStorage 均依赖此处注册）。
        AppGroup.defaults.register(defaults: [AppGroup.prefAllowCellular: true])
        // 标题栏全局全透明：无底色无毛玻璃（含滚动边缘态），仅保留标题与返回键。
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        let bar = UINavigationBar.appearance()
        bar.standardAppearance = nav
        bar.scrollEdgeAppearance = nav
        bar.compactAppearance = nav
        bar.compactScrollEdgeAppearance = nav
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
