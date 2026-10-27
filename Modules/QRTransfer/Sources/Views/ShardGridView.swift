import SwiftUI

/// 分片方块阵列。两种形态：
/// 发送端：current 高亮当前帧，onTap 非空时可点跳转（手动模式）。
/// 接收端：received 填充已收格，未收格描边强调缺片。
/// 块上直接写分片号，替代独立的数字分片提示。
/// 布局为流式换行、每行居中，方块定宽不撑满整行。
struct ShardGridView: View {
    let total: Int
    var current: Int? = nil
    var received: Set<Int> = []
    var onTap: ((Int) -> Void)? = nil

    private let spacing: CGFloat = 6

    var body: some View {
        FlowLayout(spacing: spacing) {
            if total >= 1 {
                ForEach(1...total, id: \.self) { i in block(i) }
            }
        }
    }

    @ViewBuilder
    private func block(_ i: Int) -> some View {
        let isCurrent = current == i
        let isReceived = received.contains(i)
        // current==nil 即接收端形态：未收格描边
        let isMissing = current == nil && !isReceived
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? AnyShapeStyle(.tint)
                      : isReceived ? AnyShapeStyle(Color.accentColor.opacity(0.35))
                      : AnyShapeStyle(Color(uiColor: .quaternarySystemFill)))
                .overlay {
                    if isMissing {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1)
                    }
                }
            Text("\(i)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? AnyShapeStyle(.white)
                                    : AnyShapeStyle(Color(uiColor: .secondaryLabel)))
        }
        .frame(width: 30, height: 22)
        .onTapGesture { onTap?(i) }
    }
}

/// 流式布局：子视图按序排列、行满换行，每行整体居中。
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(subviews, spacing: spacing, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: max(0, width), height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = Self.rows(subviews, spacing: spacing, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                item.sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// 按可用宽度分行；返回每行条目、行宽、行高
    private static func rows(_ subviews: Subviews, spacing: CGFloat, maxWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let item = Item(sub: sub, size: size)
            if let last = result.last, last.width + spacing + size.width <= maxWidth {
                result[result.count - 1] = Row(items: last.items + [item],
                                                width: last.width + spacing + size.width,
                                                height: max(last.height, size.height))
            } else {
                result.append(Row(items: [item], width: size.width, height: size.height))
            }
        }
        return result
    }

    private struct Item {
        let sub: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }
}
