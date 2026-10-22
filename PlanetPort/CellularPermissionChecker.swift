import CoreTelephony
import UIKit

/// "无线数据"权限检测（中国区运营商特性）。
/// 权限被拒时 App 与 extension 的所有 socket 会被系统以 ENETUNREACH/EPERM
/// 拦截，VPN 永远无法连接（2026-10-22 卡"正在初始化"的根因）。
/// CTCellularData 是系统提供的该权限唯一查询接口。
final class CellularPermissionChecker {
    private let ct = CTCellularData()
    private var onRestricted: () -> Void

    init(onRestricted: @escaping () -> Void) {
        self.onRestricted = onRestricted
    }

    /// 开始监听：立即检查一次 + 状态变化回调（权限弹窗被处理后也会触发）。
    func start() {
        ct.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            guard state == .restricted else { return }
            DispatchQueue.main.async { self?.onRestricted() }
        }
        if ct.restrictedState == .restricted {
            onRestricted()
        }
    }

    deinit {
        ct.cellularDataRestrictionDidUpdateNotifier = nil
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
