import CoreTelephony
import UIKit

/// "无线数据"权限检测（中国区运营商特性）。
/// 权限被拒时 App 与 extension 的所有 socket 会被系统以 ENETUNREACH/EPERM
/// 拦截，VPN 永远无法连接（2026-10-22 卡"正在初始化"的根因）。
/// CTCellularData 是系统提供的该权限唯一查询接口。
final class CellularPermissionChecker {
    private let ct = CTCellularData()
    private var onRestricted: () -> Void
    /// 探测在途标记：restricted 误报会连续触发，探测只发一次。
    private var probing = false

    init(onRestricted: @escaping () -> Void) {
        self.onRestricted = onRestricted
    }

    /// 开始监听：状态变化回调（权限弹窗被处理后也会触发）。
    func start() {
        ct.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            guard state == .restricted else { return }
            DispatchQueue.main.async { self?.verifyWithProbe() }
        }
        if ct.restrictedState == .restricted {
            verifyWithProbe()
        }
    }

    deinit {
        ct.cellularDataRestrictionDidUpdateNotifier = nil
    }

    /// CTCellularData 在权限未判定时（新装 App、系统弹窗尚未出现）会误报
    /// restricted；该弹窗只在 App 首次发起网络请求时才触发。因此拿到
    /// restricted 不能直接提示：先发一次网络探测促使系统完成判定/弹窗，
    /// 探测结束后也不立即下结论——被拦截的请求会立刻失败，而弹窗可能还
    /// 挂着等用户选择——轮询观察一段时间，状态一直是 restricted 才确认
    /// 是用户真的拒绝了。
    private func verifyWithProbe() {
        guard !probing else { return }
        probing = true
        var req = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.confirmStillRestricted() }
        }.resume()
    }

    /// 探测后轮询确认：给系统弹窗留出应答时间（用户点"允许"后状态会翻转为
    /// notRestricted，随即撤销告警）；持续 restricted 超过观察窗才提示。
    private func confirmStillRestricted() {
        /// 观察窗时长（秒）。期间弹窗未出现或用户未响应则放弃本轮，等下次
        /// 状态变化再查；真被拒绝的场景下轮到下一轮也会得到同样结论。
        var remaining = 6
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if self.ct.restrictedState != .restricted {
                t.invalidate()
                self.probing = false
                return
            }
            remaining -= 1
            if remaining <= 0 {
                t.invalidate()
                self.probing = false
                self.onRestricted()
            }
        }
    }

    // MARK: - 提醒限流（2 小时内只提醒一次）

    private static let lastPromptKey = "CellularPermission.lastPromptAt"
    private static let throttle: TimeInterval = 2 * 3600

    static func shouldPrompt() -> Bool {
        let last = UserDefaults.standard.double(forKey: lastPromptKey)
        return Date().timeIntervalSince1970 - last >= throttle
    }

    static func markPrompted() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastPromptKey)
    }

    /// 打开系统设置页（App 的无线数据权限在 设置→蜂窝网络→PlanetPort）。
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
