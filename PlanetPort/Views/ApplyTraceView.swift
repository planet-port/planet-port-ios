import SwiftUI

/// 数据面诊断：Extension 每次聚合应用写入的决策追踪（只读，可复制）。
/// 内容：进入聚合的网络、冲突判定、系统设置路由、转换器上下文/聚合表快照。
struct ApplyTraceView: View {
    var body: some View {
        ScrollView {
            Text(StatusStore.applyTrace.isEmpty ? "暂无数据（隧道尚未应用过配置）" : StatusStore.applyTrace)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("数据面诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                UIPasteboard.general.string = StatusStore.applyTrace
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("复制诊断信息")
        }
    }
}
