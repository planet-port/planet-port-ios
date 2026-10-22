import Foundation

enum StatusStore {
    static let notifyStatusChanged = "cn.imgozi.PlanetPortI.statusChanged"

    private static let kNodeId = "status_nodeId"
    private static let kOnline = "status_online"
    private static let kCoreVersion = "status_coreVersion"
    private static let kTunnelStatus = "status_tunnelStatus"
    private static let kNetworkStatuses = "status_networkStatuses"
    private static let kNetworkConflicts = "status_networkConflicts"
    private static let kApplyTrace = "status_applyTrace"

    static var nodeId: String {
        get { AppGroup.defaults.string(forKey: kNodeId) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kNodeId) }
    }
    static var online: Bool {
        get { AppGroup.defaults.bool(forKey: kOnline) }
        set { AppGroup.defaults.set(newValue, forKey: kOnline) }
    }
    static var coreVersion: String {
        get { AppGroup.defaults.string(forKey: kCoreVersion) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kCoreVersion) }
    }
    static var tunnelStatus: String {
        get { AppGroup.defaults.string(forKey: kTunnelStatus) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kTunnelStatus) }
    }
    /// 网络状态（nwid → ZTNetworkStatus 原始值）。存原始 Int 而非文案：
    /// 跨进程契约不依赖展示语言，UI 层用 networkStatusesTyped 取枚举。
    /// 旧版本存的是中文文案字典，升级后 cast 失败一次性回到空（预期行为）：
    /// 状态是运行时快照，隧道首个配置回调即重写，无需迁移。
    static var networkStatuses: [String: Int] {
        get { AppGroup.defaults.dictionary(forKey: kNetworkStatuses) as? [String: Int] ?? [:] }
        set { AppGroup.defaults.set(newValue, forKey: kNetworkStatuses) }
    }

    /// 类型化读取（无法识别的原始值统一落 .unknown，与详情页路径兜底一致）。
    static var networkStatusesTyped: [String: ZTNetworkStatus] {
        networkStatuses.mapValues { ZTNetworkStatus(rawValue: $0) ?? .unknown }
    }

    /// 网络冲突（nwid → 原因原始码 "address"/"subnet"）。存原始码而非文案：
    /// 跨进程契约不依赖展示语言，UI 层按码生成中文文案。
    static var networkConflicts: [String: String] {
        get { AppGroup.defaults.dictionary(forKey: kNetworkConflicts) as? [String: String] ?? [:] }
        set { AppGroup.defaults.set(newValue, forKey: kNetworkConflicts) }
    }

    /// 聚合应用诊断追踪（Extension 每次聚合应用写入的决策快照，
    /// App 诊断页只读展示；排查"网络已连接但不通"类数据面问题）。
    static var applyTrace: String {
        get { AppGroup.defaults.string(forKey: kApplyTrace) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kApplyTrace) }
    }

    static func postChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notifyStatusChanged as CFString), nil, nil, true)
    }

    /// 监听状态变化（主线程回调）；返回值持有即可保持监听
    static func observeChange(_ handler: @escaping () -> Void) -> DarwinNotifyObserver {
        DarwinNotifyObserver(name: notifyStatusChanged, handler: handler)
    }
}

/// Darwin 通知监听封装：收到系统级通知后转发到 App 内 NotificationCenter，
/// 保证主线程回调且可用惯用的 removeObserver 生命周期管理。
final class DarwinNotifyObserver: NSObject {
    private static var registered: Set<String> = []
    private static let lock = NSLock()
    private let observer: NSObjectProtocol

    init(name: String, handler: @escaping () -> Void) {
        let forwarding = "Darwin:\(name)"
        self.observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(forwarding),
            object: nil, queue: .main) { _ in handler() }
        super.init()
        DarwinNotifyObserver.registerDarwin(name: name, forwarding: forwarding)
    }

    private static func registerDarwin(name: String, forwarding: String) {
        lock.lock(); defer { lock.unlock() }
        guard !registered.contains(name) else { return }
        registered.insert(name)
        let block: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { _, _, name, _, _ in
            // 回调参数里带通知名（无法捕获上下文），据此转发到对应 App 内通知
            guard let name = name else { return }
            let s = name.rawValue as String
            NotificationCenter.default.post(name: NSNotification.Name("Darwin:" + s), object: nil)
        }
        // observer 挂在进程生命周期上（registered 集合保证同一通知只挂一次）
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passRetained(StaticToken.shared).toOpaque(),
            block,
            name as CFString, nil,
            CFNotificationSuspensionBehavior.deliverImmediately)
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }

    private final class StaticToken: NSObject {
        static let shared = StaticToken()
    }
}
