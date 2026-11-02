import SwiftUI

/// 锚定在触发行上方的确认气泡（自绘）。
/// 系统呈现已三次漂移（confirmationDialog 锚点跑偏 → action sheet 底部
/// 大条 → iOS 27.2 强制 popover 居中压在锚定行上），不再依赖系统弹窗
/// 的定位权：气泡底边由锚点 frame 直接计算，贴触发行顶边、尾尖指向
/// 行内，全版本行为一致。点气泡外任意处关闭。
struct ConfirmBubble: View {
    /// 触发行的全局 frame（GlobalAnchorReader 持续上报）
    let anchor: CGRect
    let titleKey: String.LocalizationValue
    let messageKey: String.LocalizationValue?
    let confirmKey: String.LocalizationValue
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    /// Form 行卡片可视顶边相对行内容（Text）顶边的垂直内边距。
    /// 锚点量到的是文字顶边，上提这个量后气泡底边才贴卡片可视顶边。
    private static let rowCardInset: CGFloat = 14
    /// 气泡底边与卡片顶边之间的呼吸间距
    private static let bubbleGap: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            // 锚点换算到本层局部坐标（本层 ignoresSafeArea 铺满全屏）
            let anchorTop = anchor.minY - geo.frame(in: .global).minY
                - Self.rowCardInset - Self.bubbleGap
            // 顶部对齐：盒子（高度=容器顶到卡片顶）必须从 y=0 起排，
            // 气泡底对齐盒底后才贴卡片顶边。默认 .center 会把盒子垂直
            // 居中，气泡底边落到 (屏高+锚点)/2 处。
            ZStack(alignment: .top) {
                // 全屏点击 catcher：气泡外任意点关闭
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                bubble
                    // 高度 = 容器顶到触发行卡片可视顶边的盒子，气泡底对齐
                    // 盒底：气泡底边（尾尖根部）贴按钮卡片顶边。不用
                    // alignmentGuide 换底边的写法——实测不能穿透后续修饰链。
                    .frame(maxWidth: .infinity)
                    .frame(height: max(60, anchorTop), alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    private var bubble: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(loc(titleKey))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if let messageKey {
                    Text(loc(messageKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Button(action: onConfirm) {
                Text(loc(confirmKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.quaternary))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 260)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        }
        .overlay(alignment: .bottom) {
            // 尾尖：从气泡底边向下探入触发行内，指向该行
            ArrowDown()
                .fill(.regularMaterial)
                .frame(width: 18, height: 9)
                .offset(y: 9)
        }
    }
}

/// 向下的气泡尾尖
private struct ArrowDown: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 捕获自身所在区域的全局 frame，供 ConfirmBubble 锚定按钮位置。
/// 挂在删除行的 background 上，布局或滚动变化时持续上报。
struct GlobalAnchorReader: View {
    var onFrame: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onFrame(geo.frame(in: .global)) }
                .onChange(of: geo.frame(in: .global)) { onFrame($0) }
        }
    }
}
