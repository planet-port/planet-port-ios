import UIKit

/// 首页自定义背景图存储（App 侧独有，Extension 不使用）。
/// 文件落在 Application Support，内存中由 AppState 持有发布。
enum BackgroundImageStore {
    /// 图片大小上限（防止超大图占满内存）
    static let maxBytes = 20 * 1024 * 1024

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("home-background.img")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// 校验并保存（data 必须能解码为图片且不超过上限）
    static func save(_ data: Data) throws {
        guard data.count <= maxBytes else {
            throw BackgroundImageError.tooLarge
        }
        guard UIImage(data: data) != nil else {
            throw BackgroundImageError.notImage
        }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum BackgroundImageError: LocalizedError {
    case tooLarge
    case notImage

    var errorDescription: String? {
        switch self {
        case .tooLarge: return loc("error.bg.tooLarge")
        case .notImage: return loc("error.bg.notImage")
        }
    }
}
