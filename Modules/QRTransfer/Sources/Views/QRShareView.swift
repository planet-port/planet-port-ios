import SwiftUI

/// 分享端：展示分片二维码序列。单帧退化为静态码（无控件）；
/// 多帧提供速度四档与手动模式（方块点选跳帧 + 前后按钮）。
/// 编码与渲染均在后台线程逐张完成，首张就绪即显示，避免长时间空白等待。
struct QRShareView: View {
    let title: String
    let data: Data

    @Environment(\.dismiss) private var dismiss
    @State private var frames: [String] = []
    @State private var images: [UIImage] = []
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
                    Text(images.count < frames.count
                         ? String(format: ql("qrtransfer.generating %d/%d"),
                                  images.count, frames.count)
                         : String(format: ql("qrtransfer.frame %d/%d"),
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
        .task { await build() }
        // 渲染全部就绪（images.count 变化）后才允许自动播放启动
        .task(id: "\(manual)-\(speed)-\(frames.count)-\(images.count)") { await autoplay() }
    }

    /// 已渲染图片按 index 取；该帧未就绪时取最后一张已生成的
    private var currentImage: UIImage? {
        guard !images.isEmpty else { return nil }
        return images[min(index, images.count - 1)]
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

    /// 后台编码分片，再逐张后台渲染、逐张回填主线程显示。
    private func build() async {
        let maxModules = QRTransfer.recommendedMaxModules(side: side)
        let payload = data
        do {
            let encoded = try await Task.detached(priority: .userInitiated) {
                try QRTransfer.encode(payload, maxModules: maxModules)
            }.value
            if Task.isCancelled { return }
            frames = encoded
            index = 0
            for frame in encoded {
                if Task.isCancelled { return }
                let image = await Task.detached(priority: .userInitiated) {
                    QRRender.generate(frame)?.image
                }.value
                if let image {
                    images.append(image)
                }
            }
        } catch {
            tooLarge = true
        }
    }

    private func autoplay() async {
        guard !manual, frames.count > 1, images.count == frames.count else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(speed * 1_000_000_000))
            } catch {
                return // 任务取消：不再前进
            }
            index = (index + 1) % frames.count
        }
    }

    /// 1 基分片号跳转
    private func jump(_ oneBased: Int) {
        guard frames.count > 0 else { return }
        index = (oneBased - 1 + frames.count) % frames.count
    }
}
