import SwiftUI

/// 首页 Planet 身份区(纵向居中):大图标(实色 tint 底 + 白符号,右上角状态角标)
/// + 名称 + ID 行(moon>0 时以间隔号跟随「卫星 x n」)。无 chevron,
/// 按压缩放 ≈0.97 为唯一可点暗示。
struct PlanetCardView: View {
    let planet: PlanetProfile
    let activePlanetName: String
    let isActive: Bool
    @ObservedObject var app: AppState
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 8) {
            iconWithBadge
            Text(planet.displayName)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            idLine
        }
        .frame(maxWidth: .infinity)
        // 按压缩放反馈:去 chevron 后的唯一可点暗示(点击导航仍在 HomeView 的 onTapGesture)。
        .scaleEffect(pressed ? 0.97 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            pressed = pressing
        }, perform: {})
    }

    // MARK: - 子视图

    /// 72pt 实色图标 + 右上角骑缝状态角标 + 右下角灰色齿轮（暗示整卡可点进设置）。
    private var iconWithBadge: some View {
        Image(PlanetIcon.assetName(for: planet))
            .resizable()
            .scaledToFit()
            .frame(width: 38, height: 38)
            .frame(width: 72, height: 72)
            .background(PlanetIcon.tint(for: planet),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isActive && app.hasActivatedPlanet { statusBadge }
            }
            // 右下角灰色齿轮：贴角放置，圆角外扩会把它完全挤出图标外，向内收 4pt。
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: .systemGray))
                    .offset(x: 1, y: 1)
            }
    }

    private var moonCount: Int {
        app.moonCounts[planet.id] ?? 0
    }

    /// ID 等宽 tertiary(16pt);moon>0 时以间隔号「·」(U+00B7)跟随「卫星 x n」。
    /// 点击 ID 复制(热区外扩),无常驻复制图标,成功瞬间短暂显示对勾。
    private var idLine: some View {
        let nodeId = app.planetNodeIds[planet.id] ?? "-"
        return HStack(spacing: 4) {
            CopyableValue(text: nodeId,
                          showsIcon: false,
                          font: .system(size: 16, design: .monospaced),
                          color: .secondary)
            if moonCount > 0 {
                Text("·")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Text("planetcard.moonCount \(moonCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 角标:仅隧道绑定行星显示;VPN 在跑 = 「使用中」(tint 实底白字),
    /// 未跑 = 「上次使用」(灰底 secondary 字 + 发丝描边,与背景图隔离)。
    private var statusBadge: some View {
        let running = app.vpnRunning
        return Text(running ? loc("planetcard.inUse") : loc("planetcard.lastUsed"))
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
        if isActive && app.vpnRunning {
            return app.online ? loc("status.connected") : loc("status.connecting")
        }
        return loc("status.disconnected")
    }

    private var statusColor: Color {
        if isActive && app.vpnRunning {
            return app.online ? ThemeManager.shared.success : .orange
        }
        return .secondary
    }
}
