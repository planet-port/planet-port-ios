import SwiftUI

/// 首页布局度量（HomeView 行星页与 AddPlanetPage 共享）。
enum HomeMetrics {
    /// 页面内容顶部固定间距 = 标题区高度 64 + 24 空隙（原 12，整体再下移 12）。
    /// 标题区高度为常量：6 顶距 + 36 标题行（设置按钮撑高）+ 4 行距 + 6 圆点行 + 12 底距。
    /// 标题区任何子视图（行星提示、圆点数量）变化都不改变该高度。
    static let pageTopPadding: CGFloat = 88
}
