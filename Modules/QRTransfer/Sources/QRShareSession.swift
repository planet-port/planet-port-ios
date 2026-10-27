import UIKit
import SwiftUI

/// 二维码分享会话：创建即启动编码与渲染（后台逐张产出、主线程逐张回填）。
/// 供呈现方在触发分享时（sheet 动画开始前）创建，让生成与呈现动画并行，
/// 避免 sheet 内容 .task 要等动画播完才触发导致的首帧迟滞。
@MainActor
final class QRShareSession: ObservableObject, Identifiable {

    /// sheet(item:) 的呈现标识（每次分享一个新会话）
    let id = UUID()

    @Published private(set) var frames: [String] = []
    @Published private(set) var images: [UIImage] = []
    @Published private(set) var tooLarge = false

    /// IUO：init 内创建 Task 时 [weak self] 先于本属性赋值（任务体不读它，无风险）
    private var build: Task<Void, Never>!

    init(data: Data, side: CGFloat) {
        let maxModules = QRTransfer.recommendedMaxModules(side: side)
        build = Task { [weak self] in
            do {
                let encoded = try await Task.detached(priority: .userInitiated) {
                    try QRTransfer.encode(data, maxModules: maxModules)
                }.value
                guard !Task.isCancelled else { return }
                self?.frames = encoded
                for frame in encoded {
                    guard !Task.isCancelled else { return }
                    let image = await Task.detached(priority: .userInitiated) {
                        QRRender.generate(frame)?.image
                    }.value
                    if let image {
                        self?.images.append(image)
                    }
                }
            } catch {
                self?.tooLarge = true
            }
        }
    }

    deinit { build.cancel() }
}
