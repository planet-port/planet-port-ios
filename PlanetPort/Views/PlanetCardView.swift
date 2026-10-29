import SwiftUI

/// 首页 Planet 身份区(纵向居中):大图标(实色 tint 底 + 白符号,右上角状态角标)
/// + 名称 + ID 行(moon>0 时以间隔号跟随「卫星 x n」)。无 chevron,
/// 按压缩放 ≈0.97 为唯一可点暗示。
struct PlanetCardView: View {
    let planet: PlanetProfile
    let activePlanetName: String
    let isActive: Bool
    @ObservedObject var app: AppState
    /// 图标底色取当前主题色表，改色后即时刷新。
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 8) {
            iconWithBadge
            Text(planet.displayName)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            idLine
        }
        .frame(maxWidth: .infinity)
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

    /// ID 等宽 secondary(16pt);moon>0 时以间隔号「·」(U+00B7)跟随「卫星 x n」。
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

    /// 角标:仅隧道绑定行星显示。三态:VPN 在跑 = 「使用中」(tint 实底白字);
    /// 隧道未跑但活跃行星已有启用网络(拉起中,卡片"建立隧道"阶段)= 「连接中」
    /// (orange 实底白字);否则 = 「上次使用」(灰底 secondary 字 + 发丝描边,
    /// 与背景图隔离)。判定锚定活跃行星而非选中页,滑页不扰动角标。
    private var statusBadge: some View {
        let connecting = !app.vpnRunning
            && (app.planetNetworks[app.activePlanetId]?.contains(where: \.lastActivated) ?? false)
        return Text(app.vpnRunning ? loc("planetcard.inUse")
                   : connecting ? loc("planetcard.connecting")
                   : loc("planetcard.lastUsed"))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(app.vpnRunning || connecting ? Color.white : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(
                app.vpnRunning ? AnyShapeStyle(.tint)
                : connecting ? AnyShapeStyle(Color.orange)
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

/// 按压缩放按钮样式（≈0.97 弹簧回弹）。
/// 替代 onLongPressGesture(minimumDuration: .infinity) + onTapGesture 组合：
/// 无限时长长按手势在 iOS 16 上永不 fail，会阻塞外层 tap 的识别
/// （iOS 17 改了手势优先级不复现）；Button 的 isPressed 原生提供按压态，
/// 点击与缩放共存，16/17 行为一致。
struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}
