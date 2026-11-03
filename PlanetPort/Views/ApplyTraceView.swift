import SwiftUI

/// 数据面诊断：Extension 每次聚合应用写入的决策追踪（只读，可复制）。
/// 内容：进入聚合的网络、冲突判定、系统设置路由、转换器上下文/聚合表快照。
struct ApplyTraceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(loc("trace.last"), StatusStore.applyTrace)
                section(loc("trace.events"), StatusStore.eventLog)
            }
            .padding()
        }

        .navigationTitle("trace.title")
        // 反泄漏：首页根视图恒定 .toolbar(.hidden) 在 iOS 16 会禁用推入页栏背景，显式恢复。
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                UIPasteboard.general.string = StatusStore.applyTrace + "\n\n" + StatusStore.eventLog
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(Text("trace.copy"))
        }
    }

    private func section(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(content.isEmpty ? loc("trace.empty") : content)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
