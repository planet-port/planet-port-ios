import SwiftUI

/// 首页 Planet 身份区(纵向居中):大图标(实色 tint 底 + 白符号,右上角状态角标)
/// + 名称 + ID 行(moon>0 时以间隔号跟随「卫星 x n」)。无 chevron,
/// 按压缩放 ≈0.97 为唯一可点暗示;预览形态外包虚线边框表达"占位/未创建"。
struct PlanetCardView: View {
    let planet: PlanetProfile
    let activePlanetName: String
    let isActive: Bool
    @ObservedObject var app: AppState
    /// 添加页的实时预览:状态固定为"待添加",无角标、无按压反馈。
    var isPreview = false
    @State private var pressed = false
    /// ID 行复制反馈:图标短暂变对勾。
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            iconWithBadge
            Text(planet.name)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            idLine
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, isPreview ? 14 : 0)
        .padding(.vertical, isPreview ? 14 : 0)
        // 预览形态:虚线边框 + 淡底,明确"尚未创建"的占位语义。
        .background {
            if isPreview {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5))
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
        }
        // 按压缩放反馈:去 chevron 后的唯一可点暗示(点击导航仍在 HomeView 的 onTapGesture)。
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            guard !isPreview else { return }
            pressed = pressing
        }, perform: {})
    }

    // MARK: - 子视图

    /// 72pt 实色图标 + 右上角骑缝状态角标 + 右下角灰色齿轮（暗示整卡可点进设置）。
    private var iconWithBadge: some View {
        let tint = PlanetIcon.tint(for: planet)
        return Image(systemName: PlanetIcon.symbol(for: planet))
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(tint, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isActive && app.hasActivatedPlanet { statusBadge }
            }
            // 右下角灰色齿轮：贴角放置，圆角外扩会把它完全挤出图标外，向内收 4pt。
            .overlay(alignment: .bottomTrailing) {
                if !isPreview {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(uiColor: .systemGray))
                        .offset(x: 1, y: 1)
                }
            }
    }

    private var moonCount: Int {
        app.moonCounts[planet.id] ?? 0
    }

    /// ID 等宽 tertiary(16pt,较原 footnote 加大约 20%);moon>0 时以间隔号「·」
    /// (U+00B7,垂直居中)跟随「卫星 x n」。点击复制节点 ID,复制小图标与文字同高。
    private var idLine: some View {
        let nodeId = app.planetNodeIds[planet.id] ?? "-"
        return HStack(spacing: 4) {
            Text(nodeId)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            // 复制图标:高度为 ID 文字的 2/3(用户调整),复制成功短暂变对勾反馈。
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: copied ? .semibold : .regular))
                .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            if moonCount > 0 {
                Text("·")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Text("卫星 x \(moonCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard nodeId != "-", !isPreview else { return }
            UIPasteboard.general.string = nodeId
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                withAnimation(.easeIn(duration: 0.15)) { copied = false }
            }
        }
    }

    /// 角标:仅隧道绑定行星显示;VPN 在跑 = 「使用中」(tint 实底白字),
    /// 未跑 = 「上次使用」(灰底 secondary 字 + 发丝描边,与背景图隔离)。
    private var statusBadge: some View {
        let running = app.vpnRunning
        return Text(running ? "使用中" : "上次使用")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(running ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(running ? AnyShapeStyle(.tint)
                                               : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))))
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
            // 骑缝:一半叠出图标右上角外。
            .offset(x: 10, y: -6)
    }

    // MARK: - 连接状态(由原首页节点状态卡迁移,按 Planet 维度判断;状态行暂时隐藏)

    private var statusText: String {
        if isPreview { return "待添加" }
        if isActive && app.vpnRunning {
            return app.online ? "已连接" : "连接中"
        }
        return "未连接"
    }

    private var statusColor: Color {
        if isPreview { return .secondary }
        if isActive && app.vpnRunning {
            return app.online ? .green : .orange
        }
        return .secondary
    }
}
