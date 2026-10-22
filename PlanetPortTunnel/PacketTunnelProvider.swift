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
        if let ip = Self.probeOutboundV4()?.ip {
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
        let v4Settings = NEIPv4Settings(addresses: v4.map { Self.ipOnly($0) },
                                        subnetMasks: v4.map { Self.subnetMask($0) })
        var v4Routes: [NEIPv4Route] = []
        if entry?.routeViaZeroTier == true {
            v4Routes.append(NEIPv4Route.default())
        }
        // 与 Android builder.addRoute(addressToRoute(assignedAddress), prefix) 对齐：
        // 分配地址本身不会自动保证其直连网段进入 Packet Tunnel。
        for address in v4 {
            v4Routes.append(Self.route(Self.networkCIDR4(address)))
        }
        for r in cfg.routes where r.contains(".") && (entry?.routeViaZeroTier == true || !Self.isDefaultRoute(r)) {
            v4Routes.append(Self.route(r))
        }
        v4Settings.includedRoutes = v4Routes
        // 物理接口 on-link 子网排除出隧道：防止 managed routes（如 192.168.0.0/16）
        // 把本地网关/DNS 抓进隧道形成黑洞（新域名解析失败的根因）
        v4Settings.excludedRoutes = Self.physicalOnLinkRoutes4(excludingNetworksOf: v4)
        settings.ipv4Settings = v4Settings

        // IPv6
        if !v6.isEmpty {
            let v6Settings = NEIPv6Settings(addresses: v6.map { Self.ipOnly($0) },
                                            networkPrefixLengths: v6.map { Self.prefixLen($0) as NSNumber })
            var v6Routes: [NEIPv6Route] = []
            if entry?.routeViaZeroTier == true {
                v6Routes.append(NEIPv6Route.default())
            }
            for address in v6 {
                v6Routes.append(Self.route6(Self.networkCIDR6(address)))
            }
            for r in cfg.routes where r.contains(":") && (entry?.routeViaZeroTier == true || !Self.isDefaultRoute(r)) {
                v6Routes.append(Self.route6(r))
            }
            v6Settings.includedRoutes = v6Routes
            v6Settings.excludedRoutes = Self.physicalOnLinkRoutes6(excludingNetworksOf: v6)
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
            if let ipv4 = v4.first.flatMap({ FrameConverter.parseIPv4(Self.ipOnly($0)) }) {
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

    /// UDP connect 探测内核 v4 出口的源地址与接口：源 IP 用于 socket bind
    /// （固定源地址不改变路由查找，仍走 unscoped 默认路由——IP_BOUND_IF 的
    /// scoped 查找在 extension 环境会失败，已被对照实验否证）。
    static func probeOutboundV4() -> (ifName: String, ip: in_addr)? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("8.8.8.8"))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(s, UnsafeMutablePointer(mutating: $0), &len) == 0
        } }), local.sin_family == sa_family_t(AF_INET) else { return nil }
        let sourceIP = local.sin_addr
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let ifa = p.pointee.ifa_addr, ifa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sa = ifa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            if sa.sin_addr.s_addr == sourceIP.s_addr {
                return (String(cString: p.pointee.ifa_name), sourceIP)
            }
        }
        return nil
    }

    /// 是否物理业务接口（Wi-Fi/有线 en*、蜂窝 pdp_ip*；排除 lo/utun/awdl/bridge 等虚拟接口）
    private static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// 掩码字节 → 前缀长度（接口掩码必为连续 1）
    private static func prefixLength(ofMask mask: [UInt8]) -> UInt {
        UInt(mask.reduce(0) { $0 + (8 - $1.leadingZeroBitCount) })
    }

    /// 掩码字节 → 点分十进制
    private static func maskString(_ mask: [UInt8]) -> String {
        mask.map(String.init).joined(separator: ".")
    }

    /// 物理接口 on-link IPv4 子网 → 排除路由。
    /// ZT managed routes（如 192.168.0.0/16）会覆盖本机物理局域网，把本地网关/DNS
    /// 的流量抓进隧道黑洞；排除后本地子网仍走物理网卡。
    /// excludingNetworksOf：子网与 ZT 分配地址所在网段相同时跳过，避免反过来打断 ZeroTier。
    static func physicalOnLinkRoutes4(excludingNetworksOf assigned: [String]) -> [NEIPv4Route] {
        let assignedNetworks = Set(assigned.map { networkCIDR4($0) })
        var seen = Set<String>()
        var routes: [NEIPv4Route] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard isPhysicalInterface(String(cString: p.pointee.ifa_name)) else { continue }
            guard let addrPtr = p.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = p.pointee.ifa_netmask else { continue }
            let addrBytes = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0.prefix(4)) }
            }
            let maskBytes = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0.prefix(4)) }
            }
            let network = zip(addrBytes, maskBytes).map { $0 & $1 }
            let networkStr = network.map(String.init).joined(separator: ".")
            let prefix = prefixLength(ofMask: maskBytes)
            let cidr = "\(networkStr)/\(prefix)"
            guard !seen.contains(cidr), !assignedNetworks.contains(cidr) else { continue }
            seen.insert(cidr)
            routes.append(NEIPv4Route(destinationAddress: networkStr,
                                      subnetMask: maskString(maskBytes)))
        }
        return routes
    }

    /// 物理接口 on-link IPv6 子网 → 排除路由（跳过 fe80:: 链路本地，本就不会经默认路由）。
    static func physicalOnLinkRoutes6(excludingNetworksOf assigned: [String]) -> [NEIPv6Route] {
        let assignedNetworks = Set(assigned.map { networkCIDR6($0) })
        var seen = Set<String>()
        var routes: [NEIPv6Route] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard isPhysicalInterface(String(cString: p.pointee.ifa_name)) else { continue }
            guard let addrPtr = p.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET6),
                  let maskPtr = p.pointee.ifa_netmask else { continue }
            let addrBytes = addrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(16)) }
            }
            guard !addrBytes.starts(with: [0xfe, 0x80]) else { continue }
            let maskBytes = maskPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(16)) }
            }
            let networkBytes = zip(addrBytes, maskBytes).map { $0 & $1 }
            var addr6 = in6_addr()
            withUnsafeMutableBytes(of: &addr6) { $0.copyBytes(from: networkBytes) }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr6, &buf, socklen_t(buf.count)) != nil else { continue }
            let networkStr = String(cString: buf)
            let prefix = prefixLength(ofMask: maskBytes)
            let cidr = "\(networkStr)/\(prefix)"
            guard !seen.contains(cidr), !assignedNetworks.contains(cidr) else { continue }
            seen.insert(cidr)
            routes.append(NEIPv6Route(destinationAddress: networkStr,
                                      networkPrefixLength: prefix as NSNumber))
        }
        return routes
    }

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

    /// "10.0.0.1/24" → "10.0.0.1"
    static func ipOnly(_ cidr: String) -> String {
        String(cidr.split(separator: "/").first ?? "")
    }

    /// "10.0.0.1/24" → "255.255.255.0"
    static func subnetMask(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = UInt32(parts[1]), prefix <= 32 else { return "255.255.255.0" }
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return String(format: "%d.%d.%d.%d",
                      (mask >> 24) & 0xff, (mask >> 16) & 0xff, (mask >> 8) & 0xff, mask & 0xff)
    }

    /// "10.0.0.0/24" 或 "10.0.0.0/24 via 10.0.0.1" → NEIPv4Route
    static func route(_ r: String) -> NEIPv4Route {
        let parts = r.split(separator: " ")
        let dest = parts.first.map { String($0) } ?? r
        return NEIPv4Route(destinationAddress: ipOnly(dest),
                           subnetMask: subnetMask(dest))
    }

    static func route6(_ r: String) -> NEIPv6Route {
        let parts = r.split(separator: " ")
        let dest = parts.first.map { String($0) } ?? r
        return NEIPv6Route(destinationAddress: ipOnly(dest),
                           networkPrefixLength: prefixLen(dest) as NSNumber)
    }

    static func isDefaultRoute(_ route: String) -> Bool {
        let destination = route.split(separator: " ").first.map(String.init) ?? route
        return destination == "0.0.0.0/0" || destination == "::/0"
    }

    /// "fd00::/24" → 24
    static func prefixLen(_ cidr: String) -> UInt {
        let parts = cidr.split(separator: "/")
        return parts.count == 2 ? UInt(parts[1]) ?? 64 : 64
    }

    static func networkCIDR4(_ cidr: String) -> String {
        let prefix = min(prefixLen(cidr), 32)
        guard let ip = FrameConverter.parseIPv4(ipOnly(cidr)) else { return cidr }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - UInt32(prefix))
        let network = ip & mask
        return String(format: "%u.%u.%u.%u/%u",
                      (network >> 24) & 0xff, (network >> 16) & 0xff,
                      (network >> 8) & 0xff, network & 0xff, prefix)
    }

    static func networkCIDR6(_ cidr: String) -> String {
        let prefix = min(prefixLen(cidr), 128)
        var address = in6_addr()
        guard inet_pton(AF_INET6, ipOnly(cidr), &address) == 1 else { return cidr }
        var bytes = withUnsafeBytes(of: &address) { Array($0) }
        for bit in Int(prefix)..<128 {
            bytes[bit / 8] &= ~(UInt8(1) << UInt8(7 - bit % 8))
        }
        var network = in6_addr()
        withUnsafeMutableBytes(of: &network) { raw in
            raw.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &network, &buffer, socklen_t(buffer.count)) != nil else { return cidr }
        return "\(String(cString: buffer))/\(prefix)"
    }
}

private func sockaddrPtr(_ p: UnsafeMutablePointer<sockaddr_in>) -> UnsafeMutablePointer<sockaddr> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
}

private func sockaddrPtr(_ p: UnsafeMutablePointer<sockaddr_storage>) -> UnsafeMutablePointer<sockaddr> {
    UnsafeMutableRawPointer(p).assumingMemoryBound(to: sockaddr.self)
}
