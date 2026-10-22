import SwiftUI

/// FAB（可拖动 + 左右吸附 + 位置记忆）。
/// 独立视图承载拖动状态：拖动每帧只重绘按钮自身，不触发首页（TabView 分页）重算，保证跟手。
struct FabButton: View {
    let action: () -> Void

    /// 当前中心点：nil = 默认右下；拖动吸附后持久化，启动恢复。
    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragging = false

    /// FAB 半径 28；左右吸附与屏幕边框保持 22 安全距离；垂直活动范围：标题区以下 到 底距 54。
    private static let radius: CGFloat = 28
    private static let sideMargin: CGFloat = 22
    private static let bottomMargin: CGFloat = 54
    private static let topLimit: CGFloat = 88
    private static let xKey = "HomeView.fab.x"
    private static let yKey = "HomeView.fab.y"

    var body: some View {
        GeometryReader { geo in
            label
                .position(position(in: geo.size))
                .gesture(dragGesture(size: geo.size))
                // 首次布局 GeometryReader 尺寸是 0×0，此时恢复会把坐标 clamp 成负值
                // （表现为每次打开都在左上角）；必须等真实尺寸就绪再恢复。
                .onAppear { restoreIfNeeded(in: geo.size) }
                .onChange(of: geo.size) { size in
                    restoreIfNeeded(in: size)
                }
        }
    }

    private var label: some View {
        Image(systemName: "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.tint, in: Circle())
            .shadow(color: .black.opacity(dragging ? 0.3 : 0.25),
                    radius: dragging ? 14 : 10, y: 5)
            // 拖动时轻微缩小，松手弹回——拿起/放下的手感。
            .scaleEffect(dragging ? 0.95 : 1)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityLabel("添加网络")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: 位置

    /// 默认右下角（与原固定位置一致：trailing 22 + bottom 54）。
    private func defaultPosition(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width - Self.sideMargin - Self.radius,
                y: size.height - Self.bottomMargin - Self.radius)
    }

    /// 位置约束：水平不越过左右安全边距，垂直在标题区以下、底部安全距以上。
    /// 尺寸未就绪（0×0）时原样返回，避免 clamp 出负值。
    private func clamp(_ p: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return p }
        return CGPoint(x: min(max(p.x, Self.sideMargin + Self.radius),
                              size.width - Self.sideMargin - Self.radius),
                       y: min(max(p.y, Self.topLimit + Self.radius),
                              size.height - Self.bottomMargin - Self.radius))
    }

    private func position(in size: CGSize) -> CGPoint {
        clamp(center ?? defaultPosition(size), in: size)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = position(in: size)
                }
                let start = dragStart ?? .zero
                // 跟手弹簧：与吸附动画同款曲线（阻尼 0.7），时间稍长（0.5 vs 0.35），
                // 手感统一且更绵柔。
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0)) {
                    dragging = true
                    center = clamp(CGPoint(x: start.x + value.translation.width,
                                           y: start.y + value.translation.height), in: size)
                }
            }
            .onEnded { _ in
                dragStart = nil
                var p = position(in: size)
                // 松手水平吸附到较近的一侧；苹果经典 spring 曲线（轻微回弹的阻尼弹簧）。
                p.x = p.x < size.width / 2
                    ? Self.sideMargin + Self.radius
                    : size.width - Self.sideMargin - Self.radius
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)) {
                    dragging = false
                    center = p
                }
                save(p)
            }
    }

    // MARK: 持久化

    private func save(_ p: CGPoint) {
        UserDefaults.standard.set(Double(p.x), forKey: Self.xKey)
        UserDefaults.standard.set(Double(p.y), forKey: Self.yKey)
    }

    /// 仅在无状态且尺寸就绪时恢复一次；首次安装无记录则保持 nil → 默认右下。
    private func restoreIfNeeded(in size: CGSize) {
        guard center == nil, size.width > 0, size.height > 0 else { return }
        let x = UserDefaults.standard.double(forKey: Self.xKey)
        let y = UserDefaults.standard.double(forKey: Self.yKey)
        guard x > 0, y > 0 else { return }
        center = clamp(CGPoint(x: x, y: y), in: size)
    }
}
