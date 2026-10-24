import Foundation

enum StatusStore {
    static let notifyStatusChanged = "cn.imgozi.i.PlanetPort.statusChanged"

    private static let kNodeId = "status_nodeId"
    private static let kOnline = "status_online"
    private static let kCoreVersion = "status_coreVersion"
    private static let kTunnelStatus = "status_tunnelStatus"
    private static let kNetworkStatuses = "status_networkStatuses"
    private static let kNetworkConflicts = "status_networkConflicts"
    private static let kApplyTrace = "status_applyTrace"
    private static let kEventLog = "status_eventLog"

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
    /// 网络状态（作用域键 → ZTNetworkStatus 原始值）。存原始 Int 而非文案：
    /// 跨进程契约不依赖展示语言，UI 层用 networkStatuses(planetId:) 取枚举。
    /// 旧版本存的是中文文案字典，升级后 cast 失败一次性回到空（预期行为）：
    /// 状态是运行时快照，隧道首个配置回调即重写，无需迁移。
    static var networkStatuses: [String: Int] {
        get { AppGroup.defaults.dictionary(forKey: kNetworkStatuses) as? [String: Int] ?? [:] }
        set { AppGroup.defaults.set(newValue, forKey: kNetworkStatuses) }
    }

    /// 状态键的行星作用域：同一 networkId 可存在于多个行星，核心状态只属于
    /// 产生它的行星会话。Extension 写入用隧道会话启动时捕获的行星（见
    /// PacketTunnelProvider.sessionPlanetId），行星切换重启窗口期旧会话的
    /// 写入仍落在旧命名空间，从根上杜绝跨行星串显。
    static func scopedKey(planetId: String, nwid: String) -> String {
        "\(planetId)|\(nwid)"
    }

    /// 按行星取出 nwid → 状态（键剥掉作用域前缀）。无前缀的旧格式键不匹配
    /// 任何行星前缀，自然丢弃（运行时快照，无需迁移）。
    static func networkStatuses(planetId: String) -> [String: ZTNetworkStatus] {
        let prefix = scopedKey(planetId: planetId, nwid: "")
        return networkStatuses.compactMapValues { ZTNetworkStatus(rawValue: $0) }
            .filter { $0.key.hasPrefix(prefix) }
            .reduce(into: [String: ZTNetworkStatus]()) { map, pair in
                map[String(pair.key.dropFirst(prefix.count))] = pair.value
            }
    }

    /// 网络冲突（作用域键 → 原因原始码 "address"/"subnet"/"timeout"）。存原始码
    /// 而非文案：跨进程契约不依赖展示语言，UI 层按码生成中文文案。
    /// 作用域规则与 networkStatuses 一致。
    static var networkConflicts: [String: String] {
        get { AppGroup.defaults.dictionary(forKey: kNetworkConflicts) as? [String: String] ?? [:] }
        set { AppGroup.defaults.set(newValue, forKey: kNetworkConflicts) }
    }

    /// 按行星取出 nwid → 冲突原始码（键剥掉作用域前缀）。
    static func networkConflicts(planetId: String) -> [String: String] {
        let prefix = scopedKey(planetId: planetId, nwid: "")
        return networkConflicts
            .filter { $0.key.hasPrefix(prefix) }
            .reduce(into: [String: String]()) { map, pair in
                map[String(pair.key.dropFirst(prefix.count))] = pair.value
            }
    }

    /// 聚合应用诊断追踪（Extension 每次聚合应用写入的决策快照，
    /// App 诊断页只读展示；排查"网络已连接但不通"类数据面问题）。
    static var applyTrace: String {
        get { AppGroup.defaults.string(forKey: kApplyTrace) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kApplyTrace) }
    }

    /// Extension 侧事件滚动日志（最近 40 条）：配置回调/applyConfig/聚合决策，
    /// 排查"网络未进数据面"时定位断在哪一环。
    static var eventLog: String {
        get { AppGroup.defaults.string(forKey: kEventLog) ?? "" }
        set { AppGroup.defaults.set(newValue, forKey: kEventLog) }
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
