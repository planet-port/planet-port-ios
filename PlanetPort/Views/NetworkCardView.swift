import SwiftUI

// MARK: - 网络卡片展示状态

/// 网络卡片的状态展示模型：综合隧道运行状态、网络开关与核心实时状态（枚举）
/// 得出文案与颜色——展示文案仅在此处生成，逻辑判断走枚举。
@MainActor
struct NetworkCardStatus {
    let text: String
    let color: Color

    init(entry: NetworkEntry, app: AppState) {
        // 状态只有：未连接 / 建立隧道 / 待授权 / 核心实时状态（正在初始化、在线等）。
        // 非当前隧道行星的网络也显示"未连接"——开关为关，打开即切换行星，无需中间状态。
        if !app.vpnRunning {
            self.init(text: entry.lastActivated ? "建立隧道" : "未连接",
                      color: entry.lastActivated ? .orange : .secondary)
        } else if let conflict = app.networkConflicts[entry.networkId], entry.lastActivated {
            // 冲突原始码（跨进程契约）：address=地址冲突 / subnet=网段冲突，文案在此生成
            // （App 自动断开前的瞬时窗口）
            self.init(text: Self.conflictText(conflict), color: .red)
        } else if !entry.lastActivated {
            if let last = entry.lastConflict {
                // 冲突已自动断开：显示原因 + 断开态，再次手动开启时清除记录
                self.init(text: "\(Self.conflictText(last)),断开", color: .red)
            } else {
                self.init(text: "未连接", color: .secondary)
            }
        } else if let status = app.networkStatuses[entry.networkId] {
            // 首次加入需控制器授权：统一显示"待授权"。
            if status.isPendingAuthorization {
                self.init(text: "待授权", color: .orange)
            } else {
                self.init(text: status.displayName, color: status == .ok ? .green : .orange)
            }
        } else {
            self.init(text: "等待节点响应", color: .secondary)
        }
    }

    private init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    /// 冲突原始码 → 展示文案（仅 UI 层使用）
    private static func conflictText(_ code: String) -> String {
        code == "address" ? "地址冲突" : "网段冲突"
    }
}

// MARK: - 网络卡片

/// 网络卡片（纯展示组件）：状态、开关值、地址均由外部传入，
/// 开关/点击通过回调交还 HomeView 编排（切换确认弹窗、VPN 启动流程均在上层）。
/// 行内导航用 onTapGesture（位移即失败），滑动不会误开详情页。
struct NetworkCardView: View {
    let entry: NetworkEntry
    let cardStatus: NetworkCardStatus
    /// 开关请求处理中（显示加载圈替代 Toggle）。
    let isPending: Bool
    /// 开关显示值（非当前隧道 Planet 的网络统一显示为关）。
    let appearsActive: Bool
    /// 分配的 IP（nil = 无数据/非活跃行星，显示 "-"）。
    let addresses: [String]?
    let onToggle: (Bool) -> Void
    let onTap: () -> Void
    /// 复制反馈：图标短暂变对勾。
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.networkName.isEmpty ? entry.networkId : entry.networkName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.networkId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                // 状态行：IP 紧跟状态文本之后，复制按钮在 IP 后面。
                HStack(spacing: 8) {
                    Circle()
                        .fill(cardStatus.color)
                        .frame(width: 6, height: 6)
                    Text(cardStatus.text)
                        .font(.caption)
                        .foregroundStyle(cardStatus.color)

                    if let addresses, !addresses.isEmpty {
                        // IP 与复制图标单独成组：组内间距 4（原 8 的一半），点击均可复制。
                        HStack(spacing: 4) {
                            ipTextWithHitArea(addresses)
                            copyIcon(addresses)
                        }
                    } else {
                        // 无地址数据（未连接/非活跃行星）用 "-" 占位。
                        Text("-")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = entry.networkId
                } label: {
                    Label("复制 ID", systemImage: "doc.on.doc")
                }
            }

            if isPending {
                ProgressView()
                    .frame(width: 44)
            } else {
                Toggle("", isOn: Binding(
                    get: { appearsActive },
                    set: { onToggle($0) }))
                    .labelsHidden()
                    .accessibilityLabel("启用网络 \(entry.networkName.isEmpty ? entry.networkId : entry.networkName)")
            }

            // "更多"箭头固定在最右。
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// IP 文字 + 代理热区：热区图层覆盖文字（外扩 5pt）承接点击，文字本身
    /// 不用手势，避免小字号命中区不足。热区透明不可见，仅扩大命中范围。
    private func ipTextWithHitArea(_ addresses: [String]) -> some View {
        Text(addresses.prefix(2).joined(separator: "  "))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .padding(-5)
                    .contentShape(Rectangle())
                    .onTapGesture { copyFirstIP(addresses) }
            )
    }

    /// 复制图标：与 IP 文字同色（tertiary），原尺寸放大 25%（7 → 9）。
    private func copyIcon(_ addresses: [String]) -> some View {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 9, weight: copied ? .semibold : .regular))
            .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            .padding(1)
            .contentShape(Rectangle())
            .onTapGesture { copyFirstIP(addresses) }
            .accessibilityLabel("复制 IP")
    }

    private func copyFirstIP(_ addresses: [String]) {
        UIPasteboard.general.string = addresses.first ?? ""
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeIn(duration: 0.15)) { copied = false }
        }
    }
}
