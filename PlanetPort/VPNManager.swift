import Foundation
import NetworkExtension
import os

/// App 侧 VPN 配置管理
final class VPNManager {
    static let shared = VPNManager()
    private static let log = Logger(subsystem: "cn.imgozi.i.PlanetPort", category: "VPNManager")

    private var manager: NETunnelProviderManager?
    /// configurationInvalid 恢复中标记，防止恢复路径自身无限重试。
    private var recoveringInvalidConfig = false
    /// 启动流程在途合并：iOS 单隧道，快速连点（如 VPN 未连接时先后开两个网络）
    /// 产生的并发 load/save/start 只会制造重复系统配置与偏好竞争。
    private let startQueue = DispatchQueue(label: "vpn.start")
    private var startInFlight = false
    private var startWaiters: [(Bool, String?) -> Void] = []

    /// 加载（或首次创建）VPN 配置并启动隧道（在途时合并，结果统一回调）
    func prepareAndStart(completion: @escaping (Bool, String?) -> Void) {
        startQueue.async { [weak self] in
            guard let self else { return }
            if self.startInFlight {
                self.startWaiters.append(completion)
                return
            }
            self.startInFlight = true
            self.performStart { [weak self] ok, err in
                guard let self else { return }
                self.startQueue.async {
                    self.startInFlight = false
                    let waiters = self.startWaiters
                    self.startWaiters.removeAll()
                    completion(ok, err)
                    for w in waiters { w(ok, err) }
                }
            }
        }
    }

    private func performStart(completion: @escaping (Bool, String?) -> Void) {
        loadManager { [weak self] manager, created in
            guard let self else { return }
            // 上一会话拆除未落地（.disconnecting）就 startVPNTunnel 会被系统静默
            // 吞掉——不报错也不启动，卡片卡"建立隧道"（关网络后立即重开的根因）。
            // 先等拆除完成再启动；超时放弃等待、按原流程尽力启动。
            guard manager.connection.status != .disconnecting else {
                Self.log.info("start 前等待上一会话拆除完成")
                self.waitDisconnected(timeout: 5) { _ in
                    self.performStart(completion: completion)
                }
                return
            }
            self.startLoaded(manager, created: created, completion: completion)
        }
    }

    private func startLoaded(_ manager: NETunnelProviderManager, created: Bool,
                             completion: @escaping (Bool, String?) -> Void) {
        if created {
            // 按需规则必须随首次保存一起持久化；放在保存后重载再设置的话，
            // 后续 start 不会触发 save，规则只留在内存里，断开后不生效。
            applyOnDemand(manager)
            // 首次创建：保存后必须丢弃内存对象、从偏好重载才能拿到可启动的
            // session，未重载的对象直接 startVPNTunnel 会报 configurationInvalid。
            manager.saveToPreferences { [weak self] error in
                guard let self else { return }
                if let error {
                    completion(false, loc("vpn.error.save \(error.localizedDescription)"))
                    return
                }
                self.manager = nil
                loadManager { m, _ in
                    self.start(m, completion: completion)
                }
            }
        } else {
            applyOnDemand(manager)
            manager.saveToPreferences { [weak self] _ in
                guard let self else { return }
                self.start(manager, completion: completion)
            }
        }
    }

    func stop() {
        loadManager { manager, _ in
            // 未在运行的隧道跳过：stop 用于"无网络时空跑"等自动收敛场景，
            // 可能被反复调用，保持幂等安全。
            let status = manager.connection.status
            guard status == .connected || status == .connecting || status == .reasserting else {
                Self.log.info("stop 跳过：隧道状态 \(String(describing: status), privacy: .public)")
                return
            }
            // on-demand 的 Connect 规则会在 stopVPNTunnel 后立刻把隧道拉回来
            // （表现为"关不掉"），必须先把规则从系统配置摘除再停。
            // 偏好不回写：下次开启网络时 applyOnDemand 会按偏好重新装回。
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.saveToPreferences { _ in
                    Self.log.info("stopVPNTunnel（先摘 on-demand，状态 \(String(describing: status), privacy: .public)）")
                    manager.connection.stopVPNTunnel()
                }
            } else {
                Self.log.info("stopVPNTunnel（状态 \(String(describing: status), privacy: .public)）")
                manager.connection.stopVPNTunnel()
            }
        }
    }

    /// 行星切换专用：停隧道并等待系统确认已断开。
    /// stopVPNTunnel 是异步生效的，盲等固定时长就启动新隧道，旧会话的拆除
    /// 可能晚于新启动落地、把新会话打断（切换"连一半被掐断"的根因）。
    /// 回调参数表示是否确认断开（超时则 false，调用方仍可继续切换）。
    func stopAndWait(timeout: TimeInterval = 8, completion: @escaping (Bool) -> Void) {
        loadManager { [weak self] manager, _ in
            let status = manager.connection.status
            guard status == .connected || status == .connecting || status == .reasserting else {
                Self.log.info("stopAndWait：隧道未运行（\(String(describing: status), privacy: .public)），直接视为已断开")
                completion(true)
                return
            }
            // 与 stop() 相同：先摘 on-demand，避免 Connect 规则把隧道立刻拉回。
            let doStop = {
                Self.log.info("stopAndWait stopVPNTunnel（状态 \(String(describing: status), privacy: .public)）")
                manager.connection.stopVPNTunnel()
                self?.waitDisconnected(timeout: timeout, completion: completion)
            }
            if manager.isOnDemandEnabled {
                manager.isOnDemandEnabled = false
                manager.saveToPreferences { _ in doStop() }
            } else {
                doStop()
            }
        }
    }

    /// 每 100ms 轮询隧道状态直至断开；超时放弃等待（调用方继续走启动流程）。
    private func waitDisconnected(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            connectionStatus { status in
                if status == .disconnected || status == .invalid {
                    Self.log.info("stopAndWait：已确认断开")
                    completion(true)
                } else if Date() > deadline {
                    Self.log.error("stopAndWait 超时：隧道仍 \(String(describing: status), privacy: .public)，放弃等待")
                    completion(false)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
                }
            }
        }
        check()
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
            do {
                try session.sendProviderMessage(data) { replyData in
                    guard let replyData,
                          let reply = try? JSONDecoder().decode(ProviderReply.self, from: replyData) else {
                        completion(nil)
                        return
                    }
                    completion(reply)
                }
            } catch {
                // extension 未响应等场景 sendProviderMessage 会抛错；
                // 不回调 completion 会把依赖它的串行链路（轮询/诊断）挂死。
                completion(nil)
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
            proto.providerBundleIdentifier = "cn.imgozi.i.PlanetPort.tunnel"
            proto.providerConfiguration = [:]
            proto.serverAddress = "ZeroTier"
            m.protocolConfiguration = proto
            m.localizedDescription = "Planet Port"
            m.isEnabled = true
            self.manager = m
            handler(m, true)
        }
    }

    private func isOurs(_ m: NETunnelProviderManager) -> Bool {
        guard let proto = m.protocolConfiguration as? NETunnelProviderProtocol else { return false }
        return proto.providerBundleIdentifier == "cn.imgozi.i.PlanetPort.tunnel"
    }

    /// Connect On Demand（按需连接）
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
                    completion(false, loc("vpn.error.save \(error.localizedDescription)"))
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
                    completion(false, loc("vpn.error.start \(e.localizedDescription)"))
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
                        completion(false, loc("vpn.error.start \(error.localizedDescription)"))
                    }
                }
            } else {
                completion(false, loc("vpn.error.start \(e.localizedDescription)"))
            }
        } catch {
            completion(false, loc("vpn.error.start \(error.localizedDescription)"))
        }
    }
}
