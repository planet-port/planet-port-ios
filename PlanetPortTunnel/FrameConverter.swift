import Foundation

/// IP 包 ↔ 虚拟网帧 转换层（Android TunTapAdapter 的镜像反转）。
/// - 下行（tun→核心）：L3 IP 包 → 聚合路由表最长前缀匹配选网络 → 查该网络 ARP/NDP → processVirtualNetworkFrame
/// - 上行（核心→tun）：帧回调按 nwid 分流到对应 NetworkContext（MAC/ethertype 独立传参，不含以太网头）
/// 多网络隔离：MAC/地址/ARP/NDP/pending/路由全部按网络存放在 NetworkContext，互不串网。
/// ARP/NDP 为纯软件实现（iOS 无 /proc 组播可查，采用 Android API≥29 路径）。
/// 多网络源地址 NAT：iOS 单 tun 多地址时源总选接口主地址（NEIPv4Route 无源绑定，
/// 系统层无解），出站改写为本网络地址、入站按流表回写目的，见 NAT44。
final class FrameConverter {
    private let bridge: ZTBridge
    private var contexts: [UInt64: NetworkContext] = [:]
    /// 多网络源地址 NAT（锁内使用，与 contexts 同一把锁）
    private let nat = NAT44()
    /// 激活顺序（首次 upsert 追加；聚合表同前缀先到者胜的裁决依据）
    private var order: [UInt64] = []
    private var aggregateV4: [AggregateV4Entry] = []
    private var aggregateV6: [AggregateV6Entry] = []
    /// 诊断计数：出站无路由命中丢弃（若远大于 0 说明系统路由未进 tun 或选路缺口）
    private var statNoRoute = 0
    /// 诊断计数：入站帧因无上下文丢弃（按网络计）、ARP 解析失败、未知以太类型
    private var statDropNoCtx: [UInt64: Int] = [:]
    private var statArpParseFail = 0
    private var statUnknownEther = 0
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
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let drops = statDropNoCtx
            .map { "\(String(format: "%016llx", $0.key))×\($0.value)" }
            .sorted().joined(separator: ",")
        var lines = ["contexts=\(contexts.count) aggV4=\(aggregateV4.count) aggV6=\(aggregateV6.count) NAT流表=\(nat.count) 无路由丢弃=\(statNoRoute) 无上下文丢弃=[\(drops)] ARP解析失败=\(statArpParseFail) 未知类型=\(statUnknownEther)"]
        for nwid in order {
            guard let c = contexts[nwid] else { continue }
            let v4 = c.ipv4Addresses.map(Self.dotted).joined(separator: ",")
            let pendingDetail = c.pendingV4
                .map { "\(Self.dotted($0.key))×\($0.value.count)" }
                .sorted().joined(separator: ",")
            let oldestPending = c.pendingSince.values
                .map { Int(now.timeIntervalSince($0)) }.max()
            let replyAt = c.lastArpReplyAt.map { fmt.string(from: $0) } ?? "-"
            lines.append("ctx \(String(format: "%016llx", nwid)) mac=\(String(format: "%012llx", c.mac)) v4=[\(v4)] routes=\(c.routesV4.count)/\(c.routesV6.count) 出站=\(c.statFwdV4) 入站=\(c.statInV4) ARP问=\(c.statArpReq) ARP答=\(c.statArpReply)@\(replyAt) 收问=\(c.statArpInReq)/\(c.statArpInReqHit) 闲答=\(c.statArpReplyNoPending) 核心拒=\(c.statCoreReject)(code=\(c.lastCoreRejectCode)) 保活=\(c.statKeepalive) ARP表=\(c.arp.count) 源不符=\(c.statSrcMismatch)(\(c.statSrcMismatch > 0 ? Self.dotted(c.lastSrcMismatch) : "-")) NAT出=\(c.statNatOut) NAT入=\(c.statNatIn) 待决=[\(pendingDetail)]\(oldestPending.map { " 最老=\($0)s" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    /// 统一发核心入口：记录非 OK 返回码——核心拒收时上层计数照走，
    /// 表现为"已出站"假象，双网故障需靠此计数区分"发不出去"与"发出去没回应"。
    private func coreSend(_ ctx: NetworkContext, dstMac: UInt64, etherType: UInt32, frame: Data) {
        let r = bridge.processVirtualNetworkFrame(ctx.nwid, srcMac: ctx.mac, dstMac: dstMac,
                                                  etherType: etherType, vlanId: 0, frame: frame)
        if r != 0 {
            ctx.statCoreReject += 1
            ctx.lastCoreRejectCode = Int(r)
        }
    }

    /// 是否本机某网络持有的地址（锁内；NAT 改写前置判断——只改写本机选错的源）
    private func isLocalIPv4Locked(_ ip: UInt32) -> Bool {
        contexts.values.contains { $0.ipv4Addresses.contains(ip) }
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
                // 广播/组播直送所有有 IPv4 地址的网络（组播包直接发对应组播 MAC）。
                // 注意：此路径不做源地址 NAT（保持现状），双网时源可能仍是主地址
                if dst == 0xffffffff || Self.isIPv4Multicast(dst) {
                    let dstMac: UInt64 = (dst == 0xffffffff) ? Ethernet.broadcastMAC : Self.ipv4MulticastMAC(dst)
                    for ctx in orderedContextsLocked() where !ctx.ipv4Addresses.isEmpty && ctx.mac != 0 {
                        coreSend(ctx, dstMac: dstMac, etherType: Ethernet.typeIPv4, frame: pkt)
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
                // 源地址验证 + NAT：多地址同 tun 时 iOS 总选接口主地址（双网故障根因），
                // 源不属于本网络时改写为本网络地址（TCP/UDP 登记流表供入站回写）；
                // 源不是本机任何网络地址则只计数不改写（维持现状）
                var pkt = pkt
                let src = Self.bigEndianIP32(pkt, 12)
                if !ctx.ipv4Addresses.contains(src) {
                    ctx.statSrcMismatch += 1
                    ctx.lastSrcMismatch = src
                    if isLocalIPv4Locked(src),
                       let newSrc = ctx.ipv4Addresses.first(where: { match.route.matches($0) })
                           ?? ctx.ipv4Addresses.first {
                        if let key = NAT44.outboundKey(pkt, nwid: ctx.nwid) { nat.record(key, origSrc: src) }
                        NAT44.rewriteAddress(&pkt, offset: 12, old: src, new: newSrc)
                        ctx.statNatOut += 1
                    }
                }
                guard let mac = ctx.arp.lookup(nextHop) else {
                    if (ctx.pendingV4[nextHop]?.count ?? 0) < Self.maxPendingPerTarget {
                        if ctx.pendingV4[nextHop] == nil { ctx.pendingSince[nextHop] = Date() }
                        ctx.pendingV4[nextHop, default: []].append(pkt)
                    }
                    ctx.statArpReq += 1
                    sendARPRequest(ctx, target: nextHop)
                    continue
                }
                coreSend(ctx, dstMac: mac, etherType: Ethernet.typeIPv4, frame: pkt)
                ctx.statFwdV4 += 1
            } else if version == 6, pkt.count >= 40 {
                let dst = pkt.subdata(in: 24..<40)
                if Self.isIPv6Multicast(dst) {
                    let mac = NDPTable.multicastMAC(for: dst)
                    for ctx in orderedContextsLocked() where !ctx.ipv6Addresses.isEmpty && ctx.mac != 0 {
                        coreSend(ctx, dstMac: mac, etherType: Ethernet.typeIPv6, frame: pkt)
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
                coreSend(ctx, dstMac: mac, etherType: Ethernet.typeIPv6, frame: pkt)
            }
        }
    }

    // MARK: - core -> tun；返回 (IP 包, protocolFamily)，v6 用 AF_INET6

    func handleFrameFromCore(nwid: UInt64, srcMac: UInt64, dstMac: UInt64,
                             etherType: UInt32, frame: Data) -> [(Data, Int32)] {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = contexts[nwid] else {
            statDropNoCtx[nwid, default: 0] += 1
            return []
        }
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
            // NAT 回写：本网主动发起的流（出站源被改写）回包目的=本网络地址，
            // 内核 socket 等的是原始错误源，不回写则 TCP 握手匹配不上
            var frame = frame
            if let key = NAT44.inboundKey(frame, nwid: ctx.nwid), let orig = nat.lookup(key) {
                NAT44.rewriteAddress(&frame, offset: 16, old: Self.bigEndianIP32(frame, 16), new: orig)
                ctx.statNatIn += 1
            }
            return [(frame, AF_INET)]
        default:
            statUnknownEther += 1
            return []
        }
    }

    // MARK: - ARP 处理（仅更新本网络缓存）

    private func handleARP(_ ctx: NetworkContext, payload: Data, senderMac: UInt64) {
        guard let p = ARPTable.parse(payload) else {
            statArpParseFail += 1
            return
        }
        switch p.op {
        case 1: // 请求：问 targetIP 的 MAC；若是本网络持有的地址则应答
            ctx.statArpInReq += 1
            if ctx.ipv4Addresses.contains(p.targetIP) {
                ctx.statArpInReqHit += 1
                let reply = ARPTable.reply(senderIP: p.targetIP, senderMAC: ctx.mac,
                                           targetIP: p.senderIP, targetMAC: p.senderMAC)
                coreSend(ctx, dstMac: senderMac, etherType: Ethernet.typeARP, frame: reply)
            }
        case 2: // 应答：更新本网络表 + 冲刷本网络待决包
            ctx.statArpReply += 1
            ctx.lastArpReplyAt = Date()
            ctx.arp.update(p.senderIP, mac: p.senderMAC)
            if let waiting = ctx.pendingV4.removeValue(forKey: p.senderIP) {
                ctx.pendingSince.removeValue(forKey: p.senderIP)
                for pkt in waiting {
                    coreSend(ctx, dstMac: p.senderMAC, etherType: Ethernet.typeIPv4, frame: pkt)
                }
            } else {
                ctx.statArpReplyNoPending += 1
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
                coreSend(ctx, dstMac: senderMac, etherType: Ethernet.typeIPv6,
                         frame: Self.ipv6Packet(payload: na, dst: srcIPv6))
            }
        case 136: // NA：更新本网络表 + 冲刷本网络待决包
            if let mac = p.senderMAC {
                ctx.ndp.update(p.target, mac: mac)
                if let waiting = ctx.pendingV6.removeValue(forKey: p.target) {
                    for pkt in waiting {
                        coreSend(ctx, dstMac: mac, etherType: Ethernet.typeIPv6, frame: pkt)
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
        coreSend(ctx, dstMac: Ethernet.broadcastMAC, etherType: Ethernet.typeARP, frame: req)
    }

    private func sendNeighborSolicitation(_ ctx: NetworkContext, target: Data) {
        let ns = NDPTable.neighborSolicitation(target: target, senderMAC: ctx.mac, senderIPv6: nil)
        coreSend(ctx, dstMac: NDPTable.multicastMAC(for: NDPTable.solicitedNodeMulticast(target: target)),
                 etherType: Ethernet.typeIPv6,
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
