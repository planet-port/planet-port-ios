import NetworkExtension
import Network

enum TunnelError: LocalizedError {
    case socketCreateFailed(Int32)
    case socketBindFailed(Int32)
    case coreInitFailed

    var errorDescription: String? {
        switch self {
        case .socketCreateFailed(let code):
            return "UDP socket 创建失败（errno=\(code): \(String(cString: strerror(code)))）"
        case .socketBindFailed(let code):
            return "UDP 端口绑定失败（errno=\(code): \(String(cString: strerror(code)))）"
        case .coreInitFailed:
            return "ZeroTier Core 初始化失败"
        }
    }
}

/// 隧道主体（对齐 Android ZeroTierOneService 的职责）：
/// 核心生命周期、UDP 收发、后台任务驱动、网络配置→setTunnelNetworkSettings、
/// 配置同步（Darwin notify）、AppMessage 查询。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var bridge: ZTBridge?
    private var converter: FrameConverter?
    private var udpSocket: Int32 = -1
    private var udpThread: Thread?
    private var running = false
    private var bgTimer: DispatchSourceTimer?
    private var joinedNetworks: Set<UInt64> = []
    private var orbitedMoons: Set<UInt64> = []
    /// 已应用的用户侧网络配置（nwid → (routeViaZeroTier, dnsMode, customDns)），变更时热重配隧道
    private var appliedEntries: [UInt64: (Bool, DNSMode, [String])] = [:]
    private var configObserver: DarwinNotifyObserver?
    /// 网络路径监听：接口切换（Wi-Fi↔蜂窝）或断网恢复时重启核心（对齐 Android 网络变化重启服务）
    private var pathMonitor: Network.NWPathMonitor?
    private let restartQueue = DispatchQueue(label: "zt-restart")
    private var restartWork: DispatchWorkItem?
    private var lastPathInfo: (satisfied: Bool, ifType: Network.NWInterface.InterfaceType?)?
    /// UDP 收包线程代号：核心重启后旧线程自行退出，避免两个线程争抢新 socket
    private var udpGeneration = 0

    // MARK: - 生命周期

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            try FileManager.default.createDirectory(at: AppGroup.datastore, withIntermediateDirectories: true)

            running = true

            // 1. 核心启动（UDP socket + ZTBridge + 收包线程 + join/orbit）
            try startCore()

            // 2. 后台任务 deadline 驱动 timer（对应 Android run() 循环）
            startBackgroundTimer()

            // 3. 监听 App 侧配置变更
            configObserver = DarwinNotifyObserver(name: AppConfigStore.configChangedNotification) { [weak self] in
                self?.applyConfig(fullSync: false)
            }

            // 4. 网络路径监听：切换/恢复时重启核心
            startPathMonitor()

            // 5. tun 读循环
            readPacketsLoop()

            completionHandler(nil)
        } catch {
            stopCore()
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            StatusStore.tunnelStatus = "启动失败: \(detail)"
            StatusStore.postChange()
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        restartQueue.async { [weak self] in
            guard let self else { return }
            self.restartWork?.cancel()
            self.restartWork = nil
        }
        pathMonitor?.cancel()
        pathMonitor = nil
        bgTimer?.cancel(); bgTimer = nil
        stopCore()
        StatusStore.tunnelStatus = "已停止"
        StatusStore.online = false
        StatusStore.networkStatuses = [:]
        StatusStore.postChange()
        completionHandler()
    }

    /// 核心 + UDP socket 启动（startTunnel 与网络切换重启共用）
    private func startCore() throws {
        // 1. UDP socket 绑定 9994。
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw TunnelError.socketCreateFailed(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9994).bigEndian
        // 绑定出口源 IP（UDP connect 探测内核路由决策获得）：固定源地址不改变
        // 路由查找，sendto 仍走 unscoped 默认路由；IP_BOUND_IF 的 scoped 查找
        // 在 extension 环境不可用。网络切换由 restartCore 重新探测当前出口。
        if let ip = RoutePlanner.probeOutboundV4()?.ip {
            addr.sin_addr = ip
        } else {
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        }
        guard bind(fd, sockaddrPtr(&addr), socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 else {
            let code = errno
            close(fd)
            throw TunnelError.socketBindFailed(code)
        }
        udpSocket = fd

        // 2. 核心与帧转换层
        let b = ZTBridge()
        wireCallbacks(bridge: b)
        guard b.start(withDataStorePath: AppGroup.datastore.path) else {
            throw TunnelError.coreInitFailed
        }
        bridge = b
        converter = FrameConverter(bridge: b)

        StatusStore.coreVersion = ZTBridge.coreVersion()
        StatusStore.nodeId = String(format: "%010llx", b.nodeAddress())
        StatusStore.tunnelStatus = "运行中"
        StatusStore.postChange()

        // 3. UDP 收包线程（代号递增，旧线程在 socket 关闭后自行退出）
        udpGeneration += 1
        let generation = udpGeneration
        let t = Thread(block: { [weak self] in self?.udpReceiveLoop(generation: generation) })
        t.name = "zt-udp"
        t.start()
        udpThread = t

        // 4. 重启场景：核心状态清零，按已记录的 join/orbit 集合恢复成员关系，
        //    并清空 appliedEntries 强制重配隧道（拿到新网络的物理信息）。
        if !joinedNetworks.isEmpty || !orbitedMoons.isEmpty {
            let moons = AppConfigStore.readActiveMoons()
            for nwid in joinedNetworks { b.join(nwid) }
            for worldId in orbitedMoons {
                if let moon = moons.first(where: { $0.worldId == worldId }) {
                    b.orbit(worldId, seed: moon.seed)
                }
            }
            appliedEntries = [:]
        }

        // 5. join 已配置网络 + orbit moons（对齐 Android onStartCommand 查 lastActivated）
        applyConfig(fullSync: true)
    }

    /// 核心 + UDP socket 停止（stopTunnel 与网络切换重启共用）
    private func stopCore() {
        if udpSocket >= 0 {
            let fd = udpSocket
            udpSocket = -1
            // 关闭 socket 使阻塞的 recvfrom 返回，收包线程随后检测到代号过期退出
            close(fd)
        }
        udpThread = nil
        bridge?.shutdown()
        bridge = nil
        converter = nil
    }

    /// 网络切换重启核心：身份/网络配置持久化在磁盘，1~2 秒内恢复（对齐 Android 网络变化重启服务）
    private func restartCore() {
        guard running else { return }
        StatusStore.tunnelStatus = "网络切换，重连中"
        StatusStore.online = false
        StatusStore.postChange()
        stopCore()
        do {
            try startCore()
            NSLog("[ZT] core restarted on network change")
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            StatusStore.tunnelStatus = "重连失败: \(detail)"
            StatusStore.postChange()
        }
    }

    // MARK: - 核心回调

    private func wireCallbacks(bridge: ZTBridge) {
        // 核心帧回调（callbackQueue 串行队列上）→ 剥头写 tun
        bridge.onFrame = { [weak self] nwid, srcMac, dstMac, etherType, vlanId, frame in
            guard let self, let converter = self.converter else { return }
            let packets = converter.handleFrameFromCore(srcMac: srcMac, dstMac: dstMac,
                                                        etherType: etherType, frame: frame)
            guard !packets.isEmpty else { return }
            let protos = [NSNumber](repeating: NSNumber(value: AF_INET as Int32), count: packets.count)
            self.packetFlow.writePackets(packets, withProtocols: protos)
        }

        // 物理发包：sendto
        bridge.onSendPacket = { [weak self] data, remoteAddr in
            guard let self, self.udpSocket >= 0,
                  remoteAddr.count >= MemoryLayout<sockaddr_storage>.size else { return -1 }
            var ss = sockaddr_storage()
            _ = remoteAddr.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
                guard let base = raw.baseAddress else { return false }
                memcpy(&ss, base, MemoryLayout<sockaddr_storage>.size)
                return true
            }
            var sent = -1
            let addrLen: socklen_t
            switch Int32(ss.ss_family) {
            case AF_INET:
                addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            case AF_INET6:
                addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            default:
                return EAFNOSUPPORT
            }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                sent = sendto(self.udpSocket, base, data.count, 0,
                              sockaddrPtr(&ss), addrLen)
            }
            if sent == data.count { return 0 }
            return Int32(sent < 0 ? errno : EMSGSIZE)
        }

        // 网络配置变更（对齐 Android onNetworkConfigurationUpdated → updateTunnelConfig）
        bridge.onNetworkConfig = { [weak self] nwid, op, cfg in
            self?.handleNetworkConfig(nwid: nwid, op: op, cfg: cfg)
        }

        // 事件（对齐 Android onEvent）
        bridge.onEvent = { event, _ in
            switch event {
            case "ONLINE":
                StatusStore.online = true
                StatusStore.postChange()
            case "OFFLINE":
                StatusStore.online = false
                StatusStore.postChange()
            case "FATAL_ERROR_IDENTITY_COLLISION":
                StatusStore.tunnelStatus = "致命错误：节点地址冲突"
                StatusStore.postChange()
            default:
                break
            }
        }
    }

    // MARK: - 网络配置 → setTunnelNetworkSettings

    private func handleNetworkConfig(nwid: UInt64, op: Int32, cfg: ZTNetworkConfigData) {
        let nwidStr = String(format: "%016llx", nwid)
        var statuses = StatusStore.networkStatuses
        statuses[nwidStr] = Self.statusName(cfg.status)
        StatusStore.networkStatuses = statuses
        StatusStore.postChange()

        // 状态展示所有回调都更新；隧道设置仅在 CONFIG_UPDATE 应用。
        // UP 阶段 status 仍是 REQUESTING_CONFIGURATION（无地址无路由），此时
        // setTunnelNetworkSettings 会让系统把 extension 自身流量切到 utun，
        // UDP sendto 变 EHOSTUNREACH、包发不出去 → 永远拿不到 netconf（鸡生蛋死锁）。
        // 对齐 Android ZeroTierOneService：UP 不动配置，交给第一次 CONFIG_UPDATE。
        guard op == 2 else { return }

        // 查用户配置（默认路由/DNS 模式）
        let entry = AppConfigStore.readActiveNetworks().first { $0.networkId == nwidStr }
        let disableIPv6 = AppGroup.defaults.bool(forKey: AppGroup.prefDisableIPv6)

        // 本机 MAC 与地址 → 帧转换层
        let v4 = cfg.assignedAddrs.filter { $0.contains(".") }
        let v6 = disableIPv6 ? [] : cfg.assignedAddrs.filter { $0.contains(":") }
        // 没有可用地址的配置不应用（残缺设置同样会掐断物理路由）
        guard !v4.isEmpty || !v6.isEmpty else { return }
        converter?.currentNwid = nwid
        converter?.updateNetworkInfo(mac: cfg.mac, ipv4: v4, ipv6: v6, routes: cfg.routes)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: cfg.mtu)

        // IPv4
        let v4Settings = NEIPv4Settings(addresses: v4.map { RoutePlanner.ipOnly($0) },
                                        subnetMasks: v4.map { RoutePlanner.subnetMask($0) })
        // 物理 on-link 子网（WiFi/蜂窝本地网段）从隧道路由中挖除：ZT managed routes
        // （如 192.168.0.0/16）会覆盖本机物理局域网，把本地网关/DNS 抓进隧道黑洞。
        // 做法是对 includedRoutes 做前缀差集（挖掉物理子网后分解为更具体路由），
        // 不使用 excludedRoutes——后者仅在 includedRoutes 含默认路由时才有定义，
        // 分流场景下属于未定义行为，实测（iOS 26）会扰动物理路由殃及全局上网。
        let v4Holes = RoutePlanner.physicalOnLinkPrefixes4(excludingNetworksOf: v4)
        var v4Routes: [NEIPv4Route] = []
        if entry?.routeViaZeroTier == true {
            v4Routes.append(contentsOf: RoutePlanner.expandV4("0.0.0.0/0", subtracting: v4Holes))
        }
        // 与 Android builder.addRoute(addressToRoute(assignedAddress), prefix) 对齐：
        // 分配地址本身不会自动保证其直连网段进入 Packet Tunnel。
        for address in v4 {
            v4Routes.append(RoutePlanner.route(RoutePlanner.networkCIDR4(address)))
        }
        for r in cfg.routes where r.contains(".") && (entry?.routeViaZeroTier == true || !RoutePlanner.isDefaultRoute(r)) {
            v4Routes.append(contentsOf: RoutePlanner.expandV4(r, subtracting: v4Holes))
        }
        v4Settings.includedRoutes = v4Routes
        settings.ipv4Settings = v4Settings

        // IPv6
        if !v6.isEmpty {
            let v6Settings = NEIPv6Settings(addresses: v6.map { RoutePlanner.ipOnly($0) },
                                            networkPrefixLengths: v6.map { RoutePlanner.prefixLen($0) as NSNumber })
            let v6Holes = RoutePlanner.physicalOnLinkPrefixes6(excludingNetworksOf: v6)
            var v6Routes: [NEIPv6Route] = []
            if entry?.routeViaZeroTier == true {
                v6Routes.append(contentsOf: RoutePlanner.expandV6("::/0", subtracting: v6Holes))
            }
            for address in v6 {
                v6Routes.append(RoutePlanner.route6(RoutePlanner.networkCIDR6(address)))
            }
            for r in cfg.routes where r.contains(":") && (entry?.routeViaZeroTier == true || !RoutePlanner.isDefaultRoute(r)) {
                v6Routes.append(contentsOf: RoutePlanner.expandV6(r, subtracting: v6Holes))
            }
            v6Settings.includedRoutes = v6Routes
            settings.ipv6Settings = v6Settings
        }

        // DNS（三模式，对齐 Android updateTunnelConfig）
        switch entry?.dnsMode ?? .none {
        case .network:
            if !cfg.dns.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: cfg.dns)
            }
        case .custom:
            if let dns = entry?.customDns, !dns.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: dns)
            }
        case .none:
            break
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                StatusStore.tunnelStatus = "隧道配置失败: \(error.localizedDescription)"
                StatusStore.postChange()
                return
            }
            // 组播订阅（纯软件路径：broadcast + ADI=本机 IPv4，对齐 Android API≥29）
            if let ipv4 = v4.first.flatMap({ FrameConverter.parseIPv4(RoutePlanner.ipOnly($0)) }) {
                self?.bridge?.multicastSubscribe(nwid, group: 0xffffffffffff, adi: UInt64(ipv4))
            }
        }
    }

    // MARK: - 配置同步

    /// fullSync=true：按配置全量 join；false：diff 增量（join/leave/orbit）
    private func applyConfig(fullSync: Bool) {
        guard let bridge else { return }
        let networks = AppConfigStore.readActiveNetworks()
        let moons = AppConfigStore.readActiveMoons()

        let wanted = Set(networks.filter { $0.lastActivated }.compactMap { UInt64($0.networkId, radix: 16) })
        // join 新增
        for nwid in wanted where !joinedNetworks.contains(nwid) {
            bridge.join(nwid)
            joinedNetworks.insert(nwid)
        }
        // leave 移除
        for nwid in joinedNetworks where !wanted.contains(nwid) {
            bridge.leave(nwid)
            joinedNetworks.remove(nwid)
        }
        // orbit moons（对齐 Android：join 后自动 orbit 全部已配置 moon）
        for moon in moons where !orbitedMoons.contains(moon.worldId) {
            bridge.orbit(moon.worldId, seed: moon.seed)
            orbitedMoons.insert(moon.worldId)
        }
        // 用户侧配置（默认路由/DNS）变更 → 热重配隧道（对齐 Android NetworkConfigChangedByUserEvent）
        for nwid in joinedNetworks {
            let entry = networks.first { UInt64($0.networkId, radix: 16) == nwid }
            let routeVia = entry?.routeViaZeroTier ?? false
            let dnsMode = entry?.dnsMode ?? DNSMode.none
            let customDns = entry?.customDns ?? []
            if appliedEntries[nwid]?.0 != routeVia
                || appliedEntries[nwid]?.1 != dnsMode
                || appliedEntries[nwid]?.2 != customDns {
                appliedEntries[nwid] = (routeVia, dnsMode, customDns)
                if let cfg = bridge.networkConfig(nwid) {
                    handleNetworkConfig(nwid: nwid, op: 2, cfg: cfg)
                }
            }
        }
        if fullSync {
            StatusStore.tunnelStatus = "运行中"
        }
    }

    // MARK: - 网络路径监听

    private func startPathMonitor() {
        let monitor = Network.NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: restartQueue)
    }

    /// 接口类型变化（Wi-Fi↔蜂窝↔有线）或断网恢复时，防抖后重启核心。
    /// 核心缓存的直连路径基于旧网络的 NAT 映射，接口切换后全部失效且无法主动重置。
    private func handlePathUpdate(_ path: Network.NWPath) {
        guard running else { return }
        let info: (Bool, Network.NWInterface.InterfaceType?) =
            (path.status == .satisfied, path.availableInterfaces.first?.type)
        defer { lastPathInfo = info }
        guard let last = lastPathInfo else { return }  // 首次回调仅记录基线

        let regained = !last.satisfied && info.0
        let switched = last.satisfied && info.0
            && last.1 != nil && info.1 != nil && last.1 != info.1
        guard regained || switched else { return }

        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.restartCore()
        }
        restartWork = work
        restartQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
        NSLog("[ZT] network path changed (\(String(describing: last.1)) -> \(String(describing: info.1))), core restart scheduled")
    }

    // MARK: - UDP 收包与后台任务

    private func udpReceiveLoop(generation: Int) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while running && udpGeneration == generation {
            let fd = udpSocket
            guard fd >= 0 else { break }
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = recvfrom(fd, &buf, buf.count, 0, sockaddrPtr(&from), &len)
            guard n > 0 else { continue }
            let ss = Data(bytes: &from, count: MemoryLayout<sockaddr_storage>.size)
            // 拷贝后投递，避免 buf 复用竞争
            _ = bridge?.processWirePacket(Data(buf[0..<n]), remoteAddr: ss)
        }
    }

    private func startBackgroundTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "zt-bg"))
        timer.schedule(deadline: .now() + .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let bridge = self.bridge else { return }
            let deadline = bridge.processBackgroundTasks()
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let next = max(50, min(deadline - now, 100))
            timer.schedule(deadline: .now() + .milliseconds(Int(next)))
        }
        timer.resume()
        bgTimer = timer
    }

    private func readPacketsLoop() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, let converter = self.converter else { return }
            converter.handlePacketsFromTun(packets)
            if self.running {
                self.readPacketsLoop()
            }
        }
    }

    // MARK: - App 查询（sendProviderMessage）

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let req = try? JSONDecoder().decode(ProviderRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        var reply = ProviderReply(peers: nil, nodeId: nil, online: nil, coreVersion: nil, networkConfig: nil)
        switch req.type {
        case "peers":
            reply.peers = bridge?.peers().map {
                PeerEntry(address: String(format: "%010llx", $0.address),
                          // ZT_PeerRole: 0 leaf / 1 moon / 2 planet
                          role: ["leaf", "moon", "planet"][max(0, min(2, Int($0.role)))],
                          version: $0.version,
                          latency: Int($0.latency),
                          path: $0.path)
            } ?? []
        case "status":
            if let s = bridge?.nodeStatus() {
                reply.nodeId = String(format: "%010llx", s.address)
                reply.online = s.online
            }
            reply.coreVersion = ZTBridge.coreVersion()
        case "networkConfig":
            if let nwid = req.nwid.flatMap({ UInt64($0, radix: 16) }),
               let cfg = bridge?.networkConfig(nwid) {
                reply.networkConfig = NetworkConfigSnapshot(
                    nwid: String(format: "%016llx", cfg.nwid),
                    name: cfg.name,
                    status: Self.statusName(cfg.status),
                    type: cfg.type == 1 ? "PUBLIC" : "PRIVATE",
                    mac: String(format: "%012llx", cfg.mac),
                    mtu: Int(cfg.mtu),
                    broadcastEnabled: cfg.broadcastEnabled,
                    bridge: cfg.bridge,
                    assignedAddrs: cfg.assignedAddrs,
                    routes: cfg.routes,
                    dns: cfg.dns)
            }
        default:
            break
        }
        completionHandler?(try? JSONEncoder().encode(reply))
    }

    // MARK: - 工具

    /// 路由数学与接口探测见 RoutePlanner（前缀差集、CIDR 换算、出口探测）。

    static func statusName(_ status: Int32) -> String {
        // 对齐 ZT_VirtualNetworkStatus 枚举（Core/include/ZeroTierOne.h，0..6）
        switch status {
        case 0: return "正在初始化"   // REQUESTING_CONFIGURATION
        case 1: return "在线"         // OK
        case 2: return "拒绝访问"     // ACCESS_DENIED
        case 3: return "网络不存在"   // NOT_FOUND
        case 4: return "端口错误"     // PORT_ERROR
        case 5: return "客户端过旧"   // CLIENT_TOO_OLD
        case 6: return "需要认证"     // AUTHENTICATION_REQUIRED
        default: return "未知(\(status))"
        }
    }
}

private func sockaddrPtr(_ p: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
}

private func sockaddrPtr(_ p: UnsafeMutablePointer<sockaddr_storage>) -> UnsafeMutablePointer<sockaddr> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
}
