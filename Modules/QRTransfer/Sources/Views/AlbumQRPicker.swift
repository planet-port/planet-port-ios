import SwiftUI
import PhotosUI
import Vision

/// 相册选图识别二维码：PHPicker 多选（按选择顺序）→ Vision 逐张识别 →
/// 汇总回调全部识别文本。相机流识别器（AVCaptureMetadataOutput）吃不了
/// 静态图片，静态图走 Vision 是 iOS 标准做法；两条路径在这里汇合后，
/// 识别文本交调用方各自的聚合/提取逻辑（与相机扫到完全同构）。
/// PHPicker 为进程外选择器，无需相册访问权限。
struct AlbumQRPicker: UIViewControllerRepresentable {
    /// 识别完成（按选择顺序，一张图可能多个码）；取消选择或全部无码回调空数组
    let onResult: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        // 分片传输协议需要一次选多张凑齐，不限选
        config.selectionLimit = 0
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: ([String]) -> Void
        private var dismissed = false

        init(onResult: @escaping ([String]) -> Void) { self.onResult = onResult }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !dismissed else { return }
            dismissed = true
            // onResult 必须等相册 sheet 完全收起后再触发：本组件嵌在扫码页
            // （自身也是 sheet）里，若收起动画未结束就回调，调用方随即关闭
            // 外层 sheet 会被 SwiftUI 丢弃（嵌套 sheet 关闭竞争），表现为
            // "导入成功但数据没回填"
            let done = DispatchGroup()
            done.enter()
            picker.dismiss(animated: true) { done.leave() }
            let providers = results.map(\.itemProvider)
            guard !providers.isEmpty else {
                done.notify(queue: .main) { [onResult] in onResult([]) }
                return
            }
            // 并发加载、按序汇总：分片聚合按帧 index 进行，顺序其实无关，
            // 但保持稳定顺序便于调用方与用户预期一致。
            // 注意：结果必须同步写入——若异步写回，group.leave() 先于写入完成，
            // notify 可能在写入生效前读到空数组（真机上本地小图加载极快必触发）
            var texts = Array(repeating: [String](), count: providers.count)
            let lock = NSLock()
            for (i, provider) in providers.enumerated() where provider.canLoadObject(ofClass: UIImage.self) {
                done.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { done.leave() }
                    guard let image = object as? UIImage else { return }
                    let found = Self.recognize(image)
                    lock.lock()
                    texts[i] = found
                    lock.unlock()
                }
            }
            done.notify(queue: .main) { [onResult] in
                onResult(texts.flatMap { $0 })
            }
        }

        /// Vision 识别静态图中全部二维码文本（CIDetector 已废弃，走 Vision）
        static func recognize(_ image: UIImage) -> [String] {
            guard let cg = image.cgImage else { return [] }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }
    }
}
