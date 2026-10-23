import Foundation

/// IP 包 ↔ 虚拟网帧 转换层（Android TunTapAdapter 的镜像反转）。
/// - 下行（tun→核心）：L3 IP 包 → 聚合路由表最长前缀匹配选网络 → 查该网络 ARP/NDP → processVirtualNetworkFrame
/// - 上行（核心→tun）：帧回调按 nwid 分流到对应 NetworkContext（MAC/ethertype 独立传参，不含以太网头）
/// 多网络隔离：MAC/地址/ARP/NDP/pending/路由全部按网络存放在 NetworkContext，互不串网。
/// ARP/NDP 为纯软件实现（iOS 无 /proc 组播可查，采用 Android API≥29 路径）。
final class FrameConverter {
    private let bridge: ZTBridge
    private var contexts: [UInt64: NetworkContext] = [:]
    /// 激活顺序（首次 upsert 追加；聚合表同前缀先到者胜的裁决依据）
    private var order: [UInt64] = []
    private var aggregateV4: [AggregateV4Entry] = []
    private var aggregateV6: [AggregateV6Entry] = []
    /// 诊断计数：出站无路由命中丢弃（若远大于 0 说明系统路由未进 tun 或选路缺口）
    private var statNoRoute = 0
    private let lock = NSLock()

    /// 每下一跳 pending 包上限（Network Extension 内存限制，超出丢包）
    static let maxPendingPerTarget = 16

    init(bridge: ZTBridge) {
        self.bridge = bridge
    }

    // MARK: - 上下文管理（配置回调路径）

    /// 网络配置回调：upsert 上下文并重建聚合表。
    /// enabled=false（冲突网络）不建上下文——不承载任何流量，仅保留 Core join 状态。
    func updateNetworkInfo(nwid: UInt64, enabled: Bool, mac: UInt64,
                           ipv4: [String], ipv6: [String], routes: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else {
            removeNetworkLocked(nwid)
            return
        }
        if let ctx = contexts[nwid] {
            // 已有上下文仅更新（保留 ARP/NDP/pending），不整建重建
            ctx.update(mac: mac, ipv4Strings: ipv4, ipv6Strings: ipv6, routes: routes)
        } else {
            order.append(nwid)
            contexts[nwid] = NetworkContext(nwid: nwid, mac: mac, ipv4Strings: ipv4,
                                            ipv6Strings: ipv6, routes: routes)
        }
        rebuildAggregatesLocked()
    }

    /// 网络停用：删上下文（含 ARP/NDP/pending/路由）并重建聚合表
    func removeNetwork(nwid: UInt64) {
        lock.lock(); defer { lock.unlock() }
        removeNetworkLocked(nwid)
    }

    /// reconcile：仅保留给定网络集合。配置应用在 configQueue 读文件与 leave
    /// 并发时，在途应用可能把已离开网络的上下文加回（幽灵路由）；每次应用末尾
    /// 以本次快照收敛，保证最终一致。
    func retainOnly(_ nwids: Set<UInt64>) {
        lock.lock(); defer { lock.unlock() }
        let removed = contexts.keys.filter { !nwids.contains($0) }
        guard !removed.isEmpty else { return }
        for nwid in removed {
            contexts.removeValue(forKey: nwid)
            order.removeAll { $0 == nwid }
        }
        rebuildAggregatesLocked()
    }

    private func removeNetworkLocked(_ nwid: UInt64) {
        guard contexts.removeValue(forKey: nwid) != nil else { return }
        order.removeAll { $0 == nwid }
        rebuildAggregatesLocked()
    }

    private func rebuildAggregatesLocked() {
        let ordered = orderedContextsLocked()
        aggregateV4 = NetworkContextMath.buildAggregateV4(ordered)
        aggregateV6 = NetworkContextMath.buildAggregateV6(ordered)
    }

    private func orderedContextsLocked() -> [NetworkContext] {
        order.compactMap { contexts[$0] }
    }

    /// 诊断快照（App 诊断页透出）：上下文与聚合表当前状态
    func debugSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        var lines = ["contexts=\(contexts.count) aggV4=\(aggregateV4.count) aggV6=\(aggregateV6.count) 无路由丢弃=\(statNoRoute)"]
        for nwid in order {
            guard let c = contexts[nwid] else { continue }
            let v4 = c.ipv4Addresses.map(Self.dotted).joined(separator: ",")
            lines.append("ctx \(String(format: "%016llx", nwid)) mac=\(String(format: "%012llx", c.mac)) v4=[\(v4)] routes=\(c.routesV4.count)/\(c.routesV6.count) 出站=\(c.statFwdV4) 入站=\(c.statInV4) ARP问=\(c.statArpReq) ARP答=\(c.statArpReply) 保活=\(c.statKeepalive) ARP表=\(c.arp.count) 待决=\(c.pendingV4.values.reduce(0) { $0 + $1.count })")
        }
        return lines.joined(separator: "\n")
    }

    /// host order UInt32 → 点分十进制（诊断输出用）
    static func dotted(_ ip: UInt32) -> String {
        String(format: "%d.%d.%d.%d", (ip >> 24) & 0xff, (ip >> 16) & 0xff, (ip >> 8) & 0xff, ip & 0xff)
    }

    // MARK: - tun -> core

    func handlePacketsFromTun(_ packets: [Data]) {
        lock.lock(); defer { lock.unlock() }
        guard !contexts.isEmpty else { return }
        for pkt in packets {
            guard pkt.count >= 20 else { continue }
            let version = pkt[0] >> 4
            if version == 4 {
                let dst = Self.bigEndianIP32(pkt, 16)
                // 广播/组播直送所有有 IPv4 地址的网络（组播包直接发对应组播 MAC）
                if dst == 0xffffffff || Self.isIPv4Multicast(dst) {
                    let dstMac: UInt64 = (dst == 0xffffffff) ? Ethernet.broadcastMAC : Self.ipv4MulticastMAC(dst)
                    for ctx in orderedContextsLocked() where !ctx.ipv4Addresses.isEmpty && ctx.mac != 0 {
                        bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: dstMac,
                                                          etherType: Ethernet.typeIPv4, vlanId: 0, frame: pkt)
                    }
                    continue
                }
                // 聚合表最长前缀匹配（前缀降序、同前缀先激活者胜）；无命中丢弃
                guard let match = aggregateV4.first(where: { $0.route.matches(dst) }),
                      let ctx = contexts[match.nwid], ctx.mac != 0 else {
                    statNoRoute += 1
                    continue
                }
                let nextHop = match.route.gateway ?? dst
                guard let mac = ctx.arp.lookup(nextHop) else {
                    if (ctx.pendingV4[nextHop]?.count ?? 0) < Self.maxPendingPerTarget {
                        ctx.pendingV4[nextHop, default: []].append(pkt)
                    }
                    ctx.statArpReq += 1
                    sendARPRequest(ctx, target: nextHop)
                    continue
                }
                bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: mac,
                                                  etherType: Ethernet.typeIPv4, vlanId: 0, frame: pkt)
                ctx.statFwdV4 += 1
            } else if version == 6, pkt.count >= 40 {
                let dst = pkt.subdata(in: 24..<40)
                if Self.isIPv6Multicast(dst) {
                    let mac = NDPTable.multicastMAC(for: dst)
                    for ctx in orderedContextsLocked() where !ctx.ipv6Addresses.isEmpty && ctx.mac != 0 {
                        bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: mac,
                                                          etherType: Ethernet.typeIPv6, vlanId: 0, frame: pkt)
                    }
                    continue
                }
                guard let match = aggregateV6.first(where: { $0.route.matches(dst) }),
                      let ctx = contexts[match.nwid], ctx.mac != 0 else { continue }
                let nextHop = match.route.gateway ?? dst
                guard let mac = ctx.ndp.lookup(nextHop) else {
                    if (ctx.pendingV6[nextHop]?.count ?? 0) < Self.maxPendingPerTarget {
                        ctx.pendingV6[nextHop, default: []].append(pkt)
                    }
                    sendNeighborSolicitation(ctx, target: nextHop)
                    continue
                }
                bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: mac,
                                                  etherType: Ethernet.typeIPv6, vlanId: 0, frame: pkt)
            }
        }
    }

    // MARK: - core -> tun；返回 (IP 包, protocolFamily)，v6 用 AF_INET6

    func handleFrameFromCore(nwid: UInt64, srcMac: UInt64, dstMac: UInt64,
                             etherType: UInt32, frame: Data) -> [(Data, Int32)] {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = contexts[nwid] else { return [] }
        switch etherType {
        case Ethernet.typeARP:
            handleARP(ctx, payload: frame, senderMac: srcMac)
            return []
        case Ethernet.typeIPv6:
            if NDPTable.isNDP(ipv6Packet: frame) {
                handleNDP(ctx, packet: frame, senderMac: srcMac)
                return []
            }
            return [(frame, AF_INET6)]
        case Ethernet.typeIPv4:
            ctx.statInV4 += 1
            return [(frame, AF_INET)]
        default:
            return []
        }
    }

    // MARK: - ARP 处理（仅更新本网络缓存）

    private func handleARP(_ ctx: NetworkContext, payload: Data, senderMac: UInt64) {
        guard let p = ARPTable.parse(payload) else { return }
        switch p.op {
        case 1: // 请求：问 targetIP 的 MAC；若是本网络持有的地址则应答
            if ctx.ipv4Addresses.contains(p.targetIP) {
                let reply = ARPTable.reply(senderIP: p.targetIP, senderMAC: ctx.mac,
                                           targetIP: p.senderIP, targetMAC: p.senderMAC)
                bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: senderMac,
                                                  etherType: Ethernet.typeARP, vlanId: 0, frame: reply)
            }
        case 2: // 应答：更新本网络表 + 冲刷本网络待决包
            ctx.statArpReply += 1
            ctx.arp.update(p.senderIP, mac: p.senderMAC)
            if let waiting = ctx.pendingV4.removeValue(forKey: p.senderIP) {
                for pkt in waiting {
                    bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: p.senderMAC,
                                                      etherType: Ethernet.typeIPv4, vlanId: 0, frame: pkt)
                }
            }
        default: break
        }
    }

    // MARK: - NDP 处理（仅更新本网络缓存）

    private func handleNDP(_ ctx: NetworkContext, packet: Data, senderMac: UInt64) {
        let icmp6 = packet.dropFirst(40)   // 跳过 IPv6 头
        let srcIPv6 = packet.subdata(in: 8..<24)
        guard let p = NDPTable.parse(icmp6) else { return }
        switch p.type {
        case 135: // NS：问 target 的 MAC；若是本网络持有的地址则回 NA
            if ctx.ipv6Addresses.contains(p.target) {
                let na = NDPTable.neighborAdvertisement(target: p.target, senderMAC: ctx.mac, senderIPv6: nil)
                bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: senderMac,
                                                  etherType: Ethernet.typeIPv6, vlanId: 0,
                                                  frame: Self.ipv6Packet(payload: na, dst: srcIPv6))
            }
        case 136: // NA：更新本网络表 + 冲刷本网络待决包
            if let mac = p.senderMAC {
                ctx.ndp.update(p.target, mac: mac)
                if let waiting = ctx.pendingV6.removeValue(forKey: p.target) {
                    for pkt in waiting {
                        bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: mac,
                                                          etherType: Ethernet.typeIPv6, vlanId: 0, frame: pkt)
                    }
                }
            }
        default: break
        }
    }

    /// 闲置保活：向每个活跃网络广播一个 ARP 探测帧。移动端长闲置后直连 peer 的
    /// NAT 映射会过期，且两端都在等对方先发包（无法自愈，仅 VPN 重连可救）；
    /// 周期广播让 peer 路径与 NAT 保持温热。帧仅 28 字节，耗电可忽略。
    func sendKeepalive() {
        lock.lock(); defer { lock.unlock() }
        for ctx in orderedContextsLocked() where ctx.mac != 0 {
            guard let probeIP = ctx.ipv4Addresses.first else { continue }
            ctx.statKeepalive += 1
            sendARPRequest(ctx, target: probeIP)
        }
    }

    // MARK: - 控制帧（在指定网络内发送）

    private func sendARPRequest(_ ctx: NetworkContext, target: UInt32) {
        let req = ARPTable.request(senderIP: ctx.ipv4Addresses.first ?? 0,
                                   senderMAC: ctx.mac, targetIP: target)
        bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: Ethernet.broadcastMAC,
                                          etherType: Ethernet.typeARP, vlanId: 0, frame: req)
    }

    private func sendNeighborSolicitation(_ ctx: NetworkContext, target: Data) {
        let ns = NDPTable.neighborSolicitation(target: target, senderMAC: ctx.mac, senderIPv6: nil)
        bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac,
                                          dstMac: NDPTable.multicastMAC(for: NDPTable.solicitedNodeMulticast(target: target)),
                                          etherType: Ethernet.typeIPv6, vlanId: 0,
                                          frame: Self.ipv6Packet(payload: ns, dst: target))
    }

    /// 把 ICMPv6 载荷包成最小 IPv6 包（next header 58，hop limit 255）
    private static func ipv6Packet(payload: Data, dst: Data) -> Data {
        var p = Data(capacity: 40 + payload.count)
        p.append(0x60); p.append(0); p.append(0); p.append(0)   // ver/traffic/flow
        p.append(UInt8((payload.count >> 8) & 0xff)); p.append(UInt8(payload.count & 0xff))
        p.append(58); p.append(255)                              // next header=ICMPv6, hop=255
        p.append(contentsOf: [UInt8](repeating: 0, count: 16))   // src ::
        p.append(dst)
        p.append(payload)
        return p
    }

    // MARK: - 地址工具

    /// "x.x.x.x" → host order
    static func parseIPv4(_ s: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// "x::y" → 16 字节
    static func parseIPv6Data(_ s: String) -> Data? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return Data(bytes: &addr, count: MemoryLayout<in6_addr>.size)
    }

    /// 从 IPv4 包 offset 处取大端 IP → host order
    static func bigEndianIP32(_ pkt: Data, _ offset: Int) -> UInt32 {
        (UInt32(pkt[offset]) << 24) | (UInt32(pkt[offset + 1]) << 16)
        | (UInt32(pkt[offset + 2]) << 8) | UInt32(pkt[offset + 3])
    }

    static func isIPv4Multicast(_ ip: UInt32) -> Bool {
        (ip >> 28) == 0xE
    }

    static func isIPv6Multicast(_ addr: Data) -> Bool {
        addr[0] == 0xFF
    }

    /// IPv4 组播地址 → 组播 MAC（01:00:5e + 低 23 位）
    static func ipv4MulticastMAC(_ ip: UInt32) -> UInt64 {
        0x01005e000000 | (UInt64(ip & 0x7FFFFF))
    }
}
