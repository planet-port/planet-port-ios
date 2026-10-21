import Foundation
import NetworkExtension

/// App 侧 VPN 配置管理（对应 Android 的 VpnService.prepare/startService 流程）
final class VPNManager {
    static let shared = VPNManager()

    private var manager: NETunnelProviderManager?
    /// configurationInvalid 恢复中标记，防止恢复路径自身无限重试。
    private var recoveringInvalidConfig = false

    /// 加载（或首次创建）VPN 配置并启动隧道
    func prepareAndStart(completion: @escaping (Bool, String?) -> Void) {
        loadManager { [weak self] manager, created in
            guard let self else { return }
            if created {
                // 首次创建：保存后必须丢弃内存对象、从偏好重载才能拿到可启动的
                // session，未重载的对象直接 startVPNTunnel 会报 configurationInvalid。
                manager.saveToPreferences { [weak self] error in
                    guard let self else { return }
                    if let error {
                        completion(false, "保存 VPN 配置失败: \(error.localizedDescription)")
                        return
                    }
                    self.manager = nil
                    self.loadManager { m, _ in
                        self.applyOnDemand(m)
                        self.start(m, completion: completion)
                    }
                }
            } else {
                self.applyOnDemand(manager)
                manager.saveToPreferences { [weak self] _ in
                    guard let self else { return }
                    self.start(manager, completion: completion)
                }
            }
        }
    }

    func stop() {
        loadManager { manager, _ in
            manager.connection.stopVPNTunnel()
        }
    }

    /// planet 开关等需要重启隧道生效
    func restart(completion: ((Bool, String?) -> Void)? = nil) {
        loadManager { [weak self] manager, _ in
            guard let self else { return }
            manager.connection.stopVPNTunnel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.prepareAndStart { ok, err in
                    completion?(ok, err)
                }
            }
        }
    }

    /// 设置变更只在隧道本来就在运行时热重启，避免用户改设置时意外启动 VPN。
    func restartIfRunning() {
        connectionStatus { [weak self] status in
            guard status == .connected || status == .connecting || status == .reasserting else { return }
            self?.restart()
        }
    }

    /// 立即把按需连接偏好同步到系统 VPN 配置，不需要启动隧道。
    func updateOnDemand(completion: ((Error?) -> Void)? = nil) {
        loadManager { [weak self] manager, _ in
            guard let self else { return }
            self.applyOnDemand(manager)
            manager.saveToPreferences { error in completion?(error) }
        }
    }

    /// 查询隧道状态（sendProviderMessage；隧道未运行时回调 nil）
    func query(_ req: ProviderRequest, completion: @escaping (ProviderReply?) -> Void) {
        loadManager { manager, _ in
            guard let session = manager.connection as? NETunnelProviderSession,
                  manager.connection.status == .connected || manager.connection.status == .connecting else {
                completion(nil)
                return
            }
            let data = (try? JSONEncoder().encode(req)) ?? Data()
            try? session.sendProviderMessage(data) { replyData in
                guard let replyData,
                      let reply = try? JSONDecoder().decode(ProviderReply.self, from: replyData) else {
                    completion(nil)
                    return
                }
                completion(reply)
            }
        }
    }

    /// 当前 VPN 连接状态
    func connectionStatus(completion: @escaping (NEVPNStatus) -> Void) {
        loadManager { manager, _ in
            completion(manager.connection.status)
        }
    }

    // MARK: - 私有

    private func loadManager(_ handler: @escaping (NETunnelProviderManager, Bool) -> Void) {
        // manager 缓存后复用：loadAllFromPreferences 只在首次调用。
        // 轮询（每 5s 查状态/发消息）若每次都重载系统偏好，会触发系统重估 VPN 会话，
        // 存在把活动隧道打断的风险（运行一段时间后 VPN 自动停的根因候选）。
        if let m = manager {
            handler(m, false)
            return
        }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let m = managers?.first(where: { self.isOurs($0) }) {
                self.manager = m
                handler(m, false)
                return
            }
            let m = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "cn.imgozi.PlanetPortI.tunnel"
            proto.providerConfiguration = [:]
            proto.serverAddress = "ZeroTier"
            m.protocolConfiguration = proto
            m.localizedDescription = "PlanetPort"
            m.isEnabled = true
            self.manager = m
            handler(m, true)
        }
    }

    private func isOurs(_ m: NETunnelProviderManager) -> Bool {
        guard let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == "cn.imgozi.PlanetPortI.tunnel"
    }

    /// Connect On Demand（iOS 侧补全 Android 半成品开机自启）
    private func applyOnDemand(_ m: NETunnelProviderManager) {
        let on = AppGroup.defaults.bool(forKey: AppGroup.prefConnectOnDemand)
        m.isOnDemandEnabled = on
        m.onDemandRules = on ? [NEOnDemandRuleConnect()] : []
    }

    private func start(_ m: NETunnelProviderManager, completion: @escaping (Bool, String?) -> Void) {
        // iOS 由 App 调 startVPNTunnel 时会自动激活本配置，无需用户在系统设置里选择；
        // 但用户若在系统设置中关闭过本 VPN（isEnabled=false），直接启动会报
        // configurationInvalid。先持久化启用状态再启动，做到"自动选择回本配置"。
        if !m.isEnabled {
            m.isEnabled = true
            m.saveToPreferences { error in
                if let error {
                    completion(false, "保存 VPN 配置失败: \(error.localizedDescription)")
                    return
                }
                self.startTunnel(m, completion: completion)
            }
        } else {
            startTunnel(m, completion: completion)
        }
    }

    private func startTunnel(_ m: NETunnelProviderManager, completion: @escaping (Bool, String?) -> Void) {
        do {
            try m.connection.startVPNTunnel()
            completion(true, nil)
        } catch let e as NEVPNError {
            if e.code == .configurationInvalid {
                // 配置失效：缓存对象与系统偏好脱节时，丢弃缓存重载偏好后重试一次。
                guard !recoveringInvalidConfig else {
                    completion(false, "VPN 启动失败: \(e.localizedDescription)")
                    return
                }
                recoveringInvalidConfig = true
                manager = nil
                loadManager { [weak self] m2, _ in
                    guard let self else { return }
                    m2.isEnabled = true
                    m2.saveToPreferences { _ in
                        self.startTunnel(m2) { ok, err in
                            self.recoveringInvalidConfig = false
                            completion(ok, err)
                        }
                    }
                }
            } else if e.code == .configurationStale {
                m.loadFromPreferences { _ in
                    do {
                        try m.connection.startVPNTunnel()
                        completion(true, nil)
                    } catch {
                        completion(false, "VPN 启动失败: \(error.localizedDescription)")
                    }
                }
            } else {
                completion(false, "VPN 启动失败: \(e.localizedDescription)")
            }
        } catch {
            completion(false, "VPN 启动失败: \(error.localizedDescription)")
        }
    }
}
