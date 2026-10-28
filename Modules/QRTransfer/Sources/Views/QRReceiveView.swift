import SwiftUI
import AVFoundation

/// 接收端：连续扫码聚合分片。不区分单帧/多帧——解码任意帧 → 按 index 聚合
/// → 齐全后整体校验（Base45 → 解压 → CRC）→ 通过即回调一次。
/// total/checksum 与已收集合不一致（扫到新会话）时自动清空重来；CRC 失败同样清空。
struct QRReceiveView: View {
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var denied = false
    @State private var total: Int?
    @State private var checksum: UInt32?
    @State private var chunks: [Int: String] = [:]
    @State private var corrupt = false
    @State private var finished = false
    @State private var showAlbumPicker = false
    @State private var albumError: AlbumScanError?

    /// 相册识别失败原因：无码 / 序列不完整 / 数据格式不正确
    private enum AlbumScanError {
        case noQr, incomplete, invalid

        var message: String {
            switch self {
            case .noQr: ql("qrtransfer.albumNoQr")
            case .incomplete: ql("qrtransfer.albumIncomplete")
            case .invalid: ql("qrtransfer.albumInvalid")
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if authorized {
                    ContinuousScannerView(onFrame: handle)
                        .ignoresSafeArea()
                } else if denied {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.on.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text(ql("qrtransfer.cameraDenied"))
                            .font(.headline)
                        Text(ql("qrtransfer.cameraDenied.hint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(ql("qrtransfer.goSettings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        // 相机被拒时相册识别仍可用，给无相机场景留完整通路
                        Button {
                            showAlbumPicker = true
                        } label: {
                            Label(ql("qrtransfer.album"), systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
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
                        if let albumError {
                            Text(albumError.message)
                                .font(.footnote)
                                .foregroundStyle(Color.orange)
                        } else {
                            Text(corrupt ? ql("qrtransfer.corrupt") : ql("qrtransfer.waiting"))
                                .font(.footnote)
                                .foregroundStyle(corrupt ? Color.red : Color.secondary)
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle(Text(ql("qrtransfer.receiveTitle")))
            .navigationBarTitleDisplayMode(.inline)
            // 取景器深浅不定，导航栏加材质背景保证标题/按钮始终可读
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ql("qrtransfer.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        albumError = nil
                        showAlbumPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel(Text(ql("qrtransfer.album")))
                }
            }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumQRPicker { texts in
                    // 逐帧喂现有聚合：分片/校验/会话切换逻辑与相机路径完全同构
                    guard !texts.isEmpty else {
                        albumError = .noQr
                        return
                    }
                    for text in texts { handle(text) }
                    guard !finished else { return }
                    // 解码失败（corrupt）→ 格式错误；有协议帧但没凑齐 → 序列不完整；
                    // 一张协议帧都没有 → 视为格式不正确（有码但不是本协议内容）
                    if corrupt || chunks.isEmpty {
                        albumError = .invalid
                    } else {
                        albumError = .incomplete
                    }
                }
            }
            .task { await checkPermission() }
        }
    }

    /// 相机权限未定则弹系统授权框；拒绝则展示引导页，避免取景器静默黑屏。
    private func checkPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorized = granted
            denied = !granted
        default:
            denied = true
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
