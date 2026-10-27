import SwiftUI

/// 接收端：连续扫码聚合分片。不区分单帧/多帧——解码任意帧 → 按 index 聚合
/// → 齐全后整体校验（Base45 → 解压 → CRC）→ 通过即回调一次。
/// total/checksum 与已收集合不一致（扫到新会话）时自动清空重来；CRC 失败同样清空。
struct QRReceiveView: View {
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var total: Int?
    @State private var checksum: UInt32?
    @State private var chunks: [Int: String] = [:]
    @State private var corrupt = false
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ZStack {
                ContinuousScannerView(onFrame: handle)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if let total {
                            ShardGridView(total: total, received: Set(chunks.keys))
                                .padding(.horizontal, 20)
                            Text(String(format: ql("qrtransfer.received %d/%d"),
                                        chunks.count, total))
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(corrupt ? ql("qrtransfer.corrupt") : ql("qrtransfer.waiting"))
                            .font(.footnote)
                            .foregroundStyle(corrupt ? Color.red : Color.secondary)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle(Text(ql("qrtransfer.receiveTitle")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ql("qrtransfer.cancel")) { dismiss() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard !finished, let frame = QRTransfer.parse(text) else { return }
        // 换了传输会话（total 或 CRC 不同）：丢弃旧集合
        if let t = total, t != frame.total || checksum != frame.checksum {
            chunks = [:]
        }
        total = frame.total
        checksum = frame.checksum
        chunks[frame.index] = frame.payload
        corrupt = false
        guard chunks.count == frame.total else { return }
        let all = (1...frame.total).compactMap { i -> QRFrame? in
            chunks[i].map { QRFrame(total: frame.total, index: i,
                                    checksum: frame.checksum,
                                    length: frame.length, payload: $0) }
        }
        do {
            let data = try QRTransfer.decode(all)
            finished = true
            onComplete(data)
        } catch {
            chunks = [:]
            corrupt = true
        }
    }
}
