import UIKit
import CoreImage

/// CIQRCodeGenerator 封装。输出 extent 宽 = 模块数（quiet zone 不计），
/// 用它做密度约束，不依赖内嵌容量表。
enum QRRender {
    /// 复用单例，避免一次 encode 二分探测（10+ 次调用）反复新建
    private static let context = CIContext()

    private static func make(_ text: String) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter.outputImage
    }

    /// 生成位图（scale 放大保证清晰）。返回模块数供密度判断。
    static func generate(_ text: String, scale: Int = 10) -> (image: UIImage, modules: Int)? {
        guard let output = make(text) else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cg = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return (UIImage(cgImage: cg), Int(output.extent.width))
    }

    /// 文本能否生成模块数 ≤ maxModules 的二维码（探测用，不出位图）。
    static func fits(_ text: String, maxModules: Int) -> Bool {
        guard let output = make(text) else { return false }
        return Int(output.extent.width) <= maxModules
    }
}
