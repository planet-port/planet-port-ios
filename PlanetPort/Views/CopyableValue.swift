import SwiftUI

/// 可复制值文本:点击(透明热区外扩 5pt,不改变布局)复制到剪贴板。
/// 可选常驻复制图标;复制成功后图标位置短暂变对勾(0.8s)。
/// 图标字号约为文字字高的 2/3(比例参照 NetworkCardView IP 复制图标:
/// 正文 11pt,caption2 用 9pt 由调用方传入)。
struct CopyableValue: View {
    let text: String
    /// 是否常驻复制图标;false 时仅复制成功瞬间显示对勾。
    var showsIcon: Bool = true
    var font: Font = .system(.body, design: .monospaced)
    var color: Color = .secondary
    var iconSize: CGFloat = 11
    /// 复制反馈:图标短暂变对勾。
    @State private var copied = false

    /// 占位值（空 / "—" / "-"，调用方无数据时的显示约定）：不可复制，
    /// 常驻复制图标随之隐藏，避免"看着能点、点了没反应"。
    private var isPlaceholder: Bool {
        text.isEmpty || text == "—" || text == "-"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
            if (showsIcon && !isPlaceholder) || copied {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: iconSize, weight: copied ? .semibold : .regular))
                    .foregroundStyle(copied ? AnyShapeStyle(ThemeManager.shared.success)
                                            : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
        }
        // 透明热区图层(外扩 5pt)承接点击:文字小字号时命中区不足。
        .overlay(
            Rectangle()
                .fill(Color.clear)
                .padding(-5)
                .contentShape(Rectangle())
                .onTapGesture(perform: copy)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("common.copy"))
        .accessibilityValue(Text(text))
    }

    private func copy() {
        guard !isPlaceholder else { return }
        UIPasteboard.general.string = text
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeIn(duration: 0.15)) { copied = false }
        }
    }
}

/// 详情页「标题 + 可复制值」行:标题左、值右,值整体可点复制。
struct CopyableRow: View {
    let title: String
    let text: String
    var showsIcon: Bool = true
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            CopyableValue(text: text, showsIcon: showsIcon, font: font)
        }
    }
}
