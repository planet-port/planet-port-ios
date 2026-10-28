import SwiftUI
import AVFoundation

/// 扫码页：AVFoundation 实时识别二维码，提取成功后回调关闭。
/// 提取器可定制（默认网络 ID，URL 导入场景传 extractHttpUrl）。
/// 相机权限被拒时给出引导提示。
struct QRScannerView: View {
    /// 扫码结果提取器：返回 nil 表示不是目标内容，继续扫。
    var extract: (String) -> String? = QRScannerView.extractNetworkId
    /// 识别成功回调（已提取的值）。
    var onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var denied = false
    @State private var showAlbumPicker = false

    /// 相册识别失败原因：无码 / 有码但内容不符（下载失败走既有导入失败弹窗）
    private enum AlbumScanError {
        case noQr, noUrl

        var message: LocalizedStringKey {
            switch self {
            case .noQr: "qr.albumNoQr"
            case .noUrl: "qr.albumNoUrl"
            }
        }
    }
    @State private var albumError: AlbumScanError?

    var body: some View {
        NavigationStack {
            ZStack {
                if authorized {
                    QRScannerRepresentable(extract: extract, onScanned: onScanned)
                        .ignoresSafeArea()
                } else if denied {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.on.rectangle")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("qr.deniedTitle")
                            .font(.headline)
                        Text("qr.deniedMessage")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("common.goSettings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        // 相机被拒时相册识别仍可用，给无相机场景留完整通路
                        Button {
                            showAlbumPicker = true
                        } label: {
                            Label("qr.album", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
                if let albumError {
                    VStack {
                        Spacer()
                        Text(albumError.message)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial)
                    }
                }
            }
            .navigationTitle("qr.title")
            .navigationBarTitleDisplayMode(.inline)
            // 取景器深浅不定，导航栏加材质背景保证标题/按钮始终可读
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        albumError = nil
                        showAlbumPicker = true
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel(Text("qr.album"))
                }
            }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumQRPicker { texts in
                    // 单帧提取语义：取第一个能通过提取器的码，与相机路径同构。
                    // 区分无码 / 有码但内容不符，提示才有诊断价值
                    guard !texts.isEmpty else {
                        albumError = .noQr
                        return
                    }
                    guard let hit = texts.lazy.compactMap(extract).first else {
                        albumError = .noUrl
                        return
                    }
                    onScanned(hit)
                }
            }
            .task { await checkPermission() }
        }
    }

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

    /// 提取 16 位十六进制网络 ID：内容本身合法直接用，
    /// 否则找子串（二维码里常是 "https://join.zerotier.com/xxxxxxxxxxxxxxxx" 之类）。
    static func extractNetworkId(from value: String) -> String? {
        let lowered = value.lowercased()
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        if lowered.count == 16, lowered.unicodeScalars.allSatisfy(hex.contains) {
            return lowered
        }
        guard let range = lowered.range(of: "[0-9a-f]{16}", options: .regularExpression) else {
            return nil
        }
        return String(lowered[range])
    }

    /// URL 模式提取：内容必须是 http(s) 链接，去空白后原样返回。
    static func extractHttpUrl(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return trimmed
    }
}

/// AVCaptureSession 扫码封装：metadata 输出限 qr，识别一次即停（避免连续回调）。
private struct QRScannerRepresentable: UIViewControllerRepresentable {
    var extract: (String) -> String?
    var onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScanned = { value in
            guard let extracted = extract(value) else { return }
            vc.stopScanning()
            Task { @MainActor in onScanned(extracted) }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// 承载 AVCaptureSession 的控制器：预览层 + metadata 输出。
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScanned: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var stopped = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    func stopScanning() {
        guard !stopped else { return }
        stopped = true
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !stopped,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        onScanned?(value)
    }
}
