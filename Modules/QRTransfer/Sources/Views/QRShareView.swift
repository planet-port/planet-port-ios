import SwiftUI

/// 分享端：展示分片二维码序列。单帧退化为静态码（无控件）；
/// 多帧提供速度四档与手动模式（点方块阵列直接跳帧）。
/// 编码与渲染由 QRShareSession 承担（呈现方在触发分享时创建，与 sheet
/// 动画并行生成），本视图只消费结果，首张就绪即显示。
struct QRShareView: View {
    let title: String
    @ObservedObject var session: QRShareSession

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var speed: Double = 0.5
    @State private var manual = false

    private let speeds: [Double] = [0.3, 0.5, 0.8, 1.2]
    private var side: CGFloat { UIScreen.main.bounds.width * 0.72 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if session.frames.isEmpty {
                    if session.tooLarge {
                        // ContentUnavailableView 为 iOS 17+，17 优先走系统空态；
                        // 16 等价组合。iOS 16 支持退役时删 iOS16-COMPAT 分支即可。
                        if #available(iOS 17, *) {
                            ContentUnavailableView {
                                Label(ql("qrtransfer.tooLarge"), systemImage: "exclamationmark.triangle")
                            } description: { Text(ql("qrtransfer.tooLarge.hint")) }
                        } else { // iOS16-COMPAT
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                                Text(ql("qrtransfer.tooLarge"))
                                    .font(.headline)
                                Text(ql("qrtransfer.tooLarge.hint"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 30)
                        }
                    } else {
                        ProgressView()
                        Text(ql("qrtransfer.generating"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if let image = currentImage {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: side, height: side)
                    } else {
                        ProgressView()
                    }
                    if session.images.count < session.frames.count {
                        Text(String(format: ql("qrtransfer.generating %d/%d"),
                                    session.images.count, session.frames.count))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if session.frames.count > 1 {
                        // 方块阵列顶替原数字分片提示的位置
                        ShardGridView(total: session.frames.count, current: index + 1,
                                      onTap: manual ? { jump($0) } : nil)
                            .padding(.horizontal, 20)
                        controls
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
        // 渲染全部就绪（images.count 变化）后才允许自动播放启动
        .task(id: "\(manual)-\(speed)-\(session.frames.count)-\(session.images.count)") { await autoplay() }
    }

    /// 已渲染图片按 index 取；该帧未就绪时取最后一张已生成的
    private var currentImage: UIImage? {
        guard !session.images.isEmpty else { return nil }
        return session.images[min(index, session.images.count - 1)]
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
            }
        }
        .padding(.horizontal, 20)
    }

    private func autoplay() async {
        guard !manual, session.frames.count > 1, session.images.count == session.frames.count else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(speed * 1_000_000_000))
            } catch {
                return // 任务取消：不再前进
            }
            index = (index + 1) % session.frames.count
        }
    }

    /// 1 基分片号跳转
    private func jump(_ oneBased: Int) {
        guard session.frames.count > 0 else { return }
        index = (oneBased - 1 + session.frames.count) % session.frames.count
    }
}
