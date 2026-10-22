import SwiftUI
import CoreMotion

/// 首页背景：自定义背景图（无图时退化为页面底色，不再使用默认插画）。
/// 有图时叠加页面底色薄纱（浅色 0.4 / 深色 0.78，保证身份区文字对比度），
/// 并按设置叠加 CoreMotion 重力视差——手机倾斜时背景在出血余量内平移
/// （最大 ±20pt），前景 UI 不动，形成"背景在深处"的层次。
/// 无陀螺仪（模拟器）自动退化为静止背景。
struct HomeParallaxBackground: View {
    @StateObject private var motion = GravityMotionModel()
    @Environment(\.colorScheme) private var colorScheme

    /// 自定义背景图（nil = 未设置，仅页面底色）
    let image: UIImage?
    /// 视差开关（仅 image != nil 时有意义）
    let parallaxEnabled: Bool

    /// 视差最大偏移（pt）。
    private static let parallaxRange: CGFloat = 20
    /// 出血比例：图片预放大 12%，偏移在余量内裁剪，任何角度不露底色。
    /// 余量校验：最小支持机型 375pt 宽，每边 6% = 22.5pt ≥ 偏移上限 20pt。
    private static let bleed: CGFloat = 1.12

    var body: some View {
        if let image {
            GeometryReader { proxy in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width * Self.bleed,
                           height: proxy.size.height * Self.bleed)
                    // position 居中：出血余量四边均分（每边 6%），任何方向偏移不露底色。
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .offset(x: motion.offsetX * Self.parallaxRange,
                            y: motion.offsetY * Self.parallaxRange)
            }
            .ignoresSafeArea()
            .overlay {
                Color(uiColor: .systemGroupedBackground)
                    .opacity(colorScheme == .dark ? 0.78 : 0.4)
                    .ignoresSafeArea()
            }
            .onAppear { if parallaxEnabled { motion.start() } }
            .onDisappear { motion.stop() }
            .onChange(of: parallaxEnabled) { enabled in
                if enabled { motion.start() } else { motion.stop() }
            }
        } else {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        }
    }
}

/// 重力向量 → 平滑偏移（-1...1，发布到主线程）。采样 30Hz，低通滤波 α=0.1，
/// 手机回正时偏移自然回零。仅在 start/stop 之间采样，避免后台耗电。
final class GravityMotionModel: ObservableObject {
    @Published var offsetX: CGFloat = 0
    @Published var offsetY: CGFloat = 0
    private let manager = CMMotionManager()
    private var started = false

    func start() {
        guard !started, manager.isDeviceMotionAvailable else { return }
        started = true
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let gravity = motion?.gravity else { return }
            // 手机右倾（gravity.x 增大）→ 背景向左移；y 直接取重力分量（方向手感待真机校验）。
            let targetX = CGFloat(-gravity.x)
            let targetY = CGFloat(gravity.y)
            let alpha: CGFloat = 0.1
            self.offsetX += (targetX - self.offsetX) * alpha
            self.offsetY += (targetY - self.offsetY) * alpha
        }
    }

    func stop() {
        guard started else { return }
        manager.stopDeviceMotionUpdates()
        started = false
        offsetX = 0
        offsetY = 0
    }
}
