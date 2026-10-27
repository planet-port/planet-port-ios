import SwiftUI
import AVFoundation

/// 连续扫码（区别于 App 内一次即停的 QRScannerView）：多帧二维码聚合接收用。
/// 同一内容 800ms 内只回调一次（对准静止的一帧不会刷屏，轮播自然交替放行）。
struct ContinuousScannerView: UIViewControllerRepresentable {
    var onFrame: (String) -> Void

    func makeUIViewController(context: Context) -> ContinuousScannerController {
        let vc = ContinuousScannerController()
        vc.onFrame = onFrame
        return vc
    }

    func updateUIViewController(_ uiViewController: ContinuousScannerController, context: Context) {}
}

final class ContinuousScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFrame: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastValue: String?
    private var lastTime = Date.distantPast

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
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        let now = Date()
        if value == lastValue, now.timeIntervalSince(lastTime) < 0.8 { return }
        lastValue = value
        lastTime = now
        onFrame?(value)
    }
}
