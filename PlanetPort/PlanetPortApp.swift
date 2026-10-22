import SwiftUI

@main
struct PlanetPortApp: App {
    init() {
        // 偏好默认值：未写入过时按"允许移动数据"处理（HomeView 的 bool 判断与
        // PrefsView 的 AppStorage 均依赖此处注册）。
        AppGroup.defaults.register(defaults: [AppGroup.prefAllowCellular: true])
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
