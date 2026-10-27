import SwiftUI

/// 分片方块阵列。两种形态：
/// 发送端：current 高亮当前帧，onTap 非空时可点跳转（手动模式）。
/// 接收端：received 填充已收格，未收格描边强调缺片。
struct ShardGridView: View {
    let total: Int
    var current: Int? = nil
    var received: Set<Int> = []
    var onTap: ((Int) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 30), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
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
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isCurrent ? AnyShapeStyle(.tint)
                  : isReceived ? AnyShapeStyle(Color(uiColor: .systemFill).opacity(0.35))
                  : AnyShapeStyle(Color(uiColor: .quaternarySystemFill)))
            .overlay {
                if isMissing {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1)
                }
            }
            .frame(height: 22)
            .onTapGesture { onTap?(i) }
    }
}
