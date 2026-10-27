import SwiftUI

/// 分享端：展示分片二维码序列。单帧退化为静态码（无控件）；
/// 多帧提供速度四档与手动模式（方块点选跳帧 + 前后按钮）。
struct QRShareView: View {
    let title: String
    let data: Data

    @Environment(\.dismiss) private var dismiss
    @State private var frames: [String] = []
    @State private var tooLarge = false
    @State private var index = 0
    @State private var speed: Double = 0.5
    @State private var manual = false

    private let speeds: [Double] = [0.3, 0.5, 0.8, 1.2]
    private var side: CGFloat { UIScreen.main.bounds.width * 0.72 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if frames.isEmpty {
                    if tooLarge {
                        ContentUnavailableView {
                            Label(ql("qrtransfer.tooLarge"), systemImage: "exclamationmark.triangle")
                        } description: { Text(ql("qrtransfer.tooLarge.hint")) }
                    } else {
                        ProgressView()
                    }
                } else {
                    if let render = QRRender.generate(frames[index]) {
                        Image(uiImage: render.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: side, height: side)
                            .animation(.easeInOut(duration: 0.15), value: index)
                    }
                    Text(String(format: ql("qrtransfer.frame %d/%d"),
                                index + 1, frames.count))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if frames.count > 1 {
                        controls
                        ShardGridView(total: frames.count, current: index + 1,
                                      onTap: manual ? { jump($0) } : nil)
                            .padding(.horizontal, 20)
                    }
                    Spacer()
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ql("qrtransfer.done")) { dismiss() }
                }
            }
        }
        .task { encode() }
        .task(id: "\(manual)-\(speed)-\(frames.count)") { await autoplay() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle(ql("qrtransfer.manual"), isOn: $manual)
                .font(.subheadline)
            if !manual {
                Picker(ql("qrtransfer.speed"), selection: $speed) {
                    ForEach(speeds, id: \.self) { s in
                        Text(String(format: "%.1fs", s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            } else {
                HStack(spacing: 28) {
                    Button {
                        jump(index)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Button {
                        jump(index + 2)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
    }

    private func encode() {
        let maxModules = QRTransfer.recommendedMaxModules(side: side)
        do {
            frames = try QRTransfer.encode(data, maxModules: maxModules)
            index = 0
        } catch {
            tooLarge = true
        }
    }

    private func autoplay() async {
        guard !manual, frames.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(speed * 1_000_000_000))
            index = (index + 1) % frames.count
        }
    }

    /// 1 基分片号跳转
    private func jump(_ oneBased: Int) {
        guard frames.count > 0 else { return }
        index = (oneBased - 1 + frames.count) % frames.count
    }
}
