import Foundation

/// IP 包 ↔ 虚拟网帧 转换层（Android TunTapAdapter 的镜像反转）。
/// - 下行（tun→核心）：NEPacketTunnelFlow 的 L3 IP 包 → 查表补 MAC → processVirtualNetworkFrame
/// - 上行（核心→tun）：核心的帧回调（MAC/ethertype 独立传参，不含以太网头）→ 返回 IP 包写回 packetFlow
/// ARP/NDP 为纯软件实现（iOS 无 /proc 组播可查，采用 Android API≥29 路径）。
final class FrameConverter {
    private let bridge: ZTBridge
    private var arp = ARPTable()
    private var ndp = NDPTable()
    private var pendingV4: [UInt32: [Data]] = [:]   // 等 ARP 应答的包
    private var pendingV6: [Data: [Data]] = [:]     // 等 NA 应答的包（key 为 16 字节目的地址）
    private var myMAC: UInt64 = 0
    private var myIPv4: [UInt32] = []
    private var myIPv6: [Data] = []
    private var routesV4: [IPv4Route] = []
    private var routesV6: [IPv6Route] = []
    private let lock = NSLock()

    /// 当前活动网络 ID（PacketTunnelProvider 注入；单网络连接模型，对齐 Android 主场景）
    var currentNwid: UInt64 = 0

    init(bridge: ZTBridge) {
        self.bridge = bridge
    }

    /// 网络配置回调时更新本机信息（ARP/NDP 应答要用）
    func updateNetworkInfo(mac: UInt64, ipv4: [String], ipv6: [String], routes: [String]) {
        lock.lock(); defer { lock.unlock() }
        self.myMAC = mac
        self.myIPv4 = ipv4.compactMap { Self.parseIPv4(Self.ipOnly($0)) }
        self.myIPv6 = ipv6.compactMap { Self.parseIPv6Data(Self.ipOnly($0)) }
        self.routesV4 = (ipv4.map { Self.networkCIDR($0) } + routes).compactMap(Self.parseIPv4Route)
            .sorted { $0.prefix > $1.prefix }
        self.routesV6 = (ipv6.map { Self.networkCIDR($0) } + routes).compactMap(Self.parseIPv6Route)
            .sorted { $0.prefix > $1.prefix }
    }

    // MARK: - tun -> core

    func handlePacketsFromTun(_ packets: [Data]) {
        lock.lock(); defer { lock.unlock() }
        guard myMAC != 0 else { return }
        for pkt in packets {
            guard pkt.count >= 20, currentNwid != 0 else { continue }
            let version = pkt[0] >> 4
            if version == 4 {
                let dst = Self.bigEndianIP32(pkt, 16)
                // 广播/组播直送（对齐 Android：组播包直接发对应组播 MAC）
                if dst == 0xffffffff || Self.isIPv4Multicast(dst) {
                    let dstMac: UInt64 = (dst == 0xffffffff) ? Ethernet.broadcastMAC : Self.ipv4MulticastMAC(dst)
                    send(pkt, to: dstMac, ethertype: Ethernet.typeIPv4)
                    continue
                }
                let nextHop = nextHopV4(for: dst)
                guard let mac = arp.lookup(nextHop) else {
                    pendingV4[nextHop, default: []].append(pkt)
                    sendARPRequest(target: nextHop)
                    continue
                }
                send(pkt, to: mac, ethertype: Ethernet.typeIPv4)
            } else if version == 6, pkt.count >= 40 {
                let dst = pkt.subdata(in: 24..<40)
                if Self.isIPv6Multicast(dst) {
                    send(pkt, to: NDPTable.multicastMAC(for: dst), ethertype: Ethernet.typeIPv6)
                    continue
                }
                let nextHop = nextHopV6(for: dst)
                guard let mac = ndp.lookup(nextHop) else {
                    pendingV6[nextHop, default: []].append(pkt)
                    sendNeighborSolicitation(target: nextHop)
                    continue
                }
                send(pkt, to: mac, ethertype: Ethernet.typeIPv6)
            }
        }
    }

    // MARK: - core -> tun；返回应写入 packetFlow 的 IP 包

    func handleFrameFromCore(srcMac: UInt64, dstMac: UInt64, etherType: UInt32, frame: Data) -> [Data] {
        switch etherType {
        case Ethernet.typeARP:
            handleARP(payload: frame, senderMac: srcMac)
            return []
        case Ethernet.typeIPv6:
            if NDPTable.isNDP(ipv6Packet: frame) {
                handleNDP(packet: frame, senderMac: srcMac)
                return []
            }
            return [frame]
        case Ethernet.typeIPv4:
            return [frame]
        default:
            return []
        }
    }

    // MARK: - ARP 处理

    private func handleARP(payload: Data, senderMac: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard let p = ARPTable.parse(payload) else { return }
        switch p.op {
        case 1: // 请求：问 targetIP 的 MAC；若是我们持有的地址则应答（对齐 Android ARPTable.processArpPacket）
            if myIPv4.contains(p.targetIP) {
                let reply = ARPTable.reply(senderIP: p.targetIP, senderMAC: myMAC,
                                           targetIP: p.senderIP, targetMAC: p.senderMAC)
                sendControl(reply, to: senderMac, ethertype: Ethernet.typeARP)
            }
        case 2: // 应答：更新表 + 冲刷待决包
            arp.update(p.senderIP, mac: p.senderMAC)
            if let waiting = pendingV4.removeValue(forKey: p.senderIP) {
                for pkt in waiting {
                    send(pkt, to: p.senderMAC, ethertype: Ethernet.typeIPv4)
                }
            }
        default: break
        }
    }

    // MARK: - NDP 处理

    private func handleNDP(packet: Data, senderMac: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let icmp6 = packet.dropFirst(40)   // 跳过 IPv6 头
        let srcIPv6 = packet.subdata(in: 8..<24)
        guard let p = NDPTable.parse(icmp6) else { return }
        switch p.type {
        case 135: // NS：问 target 的 MAC；若是我们持有的地址则回 NA
            if myIPv6.contains(p.target) {
                let na = NDPTable.neighborAdvertisement(target: p.target, senderMAC: myMAC, senderIPv6: nil)
                sendControl(Self.ipv6Packet(payload: na, dst: srcIPv6),
                            to: senderMac, ethertype: Ethernet.typeIPv6)
            }
        case 136: // NA：更新表 + 冲刷待决包
            if let mac = p.senderMAC {
                ndp.update(p.target, mac: mac)
                if let waiting = pendingV6.removeValue(forKey: p.target) {
                    for pkt in waiting {
                        send(pkt, to: mac, ethertype: Ethernet.typeIPv6)
                    }
                }
            }
        default: break
        }
    }

    // MARK: - 私有发送

    private func send(_ pkt: Data, to mac: UInt64, ethertype: UInt32) {
        bridge.processVirtualNetworkFrame(currentNwid, srcMac: myMAC, dstMac: mac,
                                          etherType: ethertype, vlanId: 0, frame: pkt)
    }

    /// 控制帧（ARP/NDP 回复）
    private func sendControl(_ payload: Data, to mac: UInt64, ethertype: UInt32) {
        bridge.processVirtualNetworkFrame(currentNwid, srcMac: myMAC, dstMac: mac,
                                          etherType: ethertype, vlanId: 0, frame: payload)
    }

    private func sendARPRequest(target: UInt32) {
        let req = ARPTable.request(senderIP: myIPv4.first ?? 0, senderMAC: myMAC, targetIP: target)
        bridge.processVirtualNetworkFrame(currentNwid, srcMac: myMAC, dstMac: Ethernet.broadcastMAC,
                                          etherType: Ethernet.typeARP, vlanId: 0, frame: req)
    }

    private func sendNeighborSolicitation(target: Data) {
        let ns = NDPTable.neighborSolicitation(target: target, senderMAC: myMAC, senderIPv6: nil)
        bridge.processVirtualNetworkFrame(currentNwid, srcMac: myMAC,
                                          dstMac: NDPTable.multicastMAC(for: NDPTable.solicitedNodeMulticast(target: target)),
                                          etherType: Ethernet.typeIPv6, vlanId: 0,
                                          frame: Self.ipv6Packet(payload: ns, dst: target))
    }

    private func nextHopV4(for destination: UInt32) -> UInt32 {
        routesV4.first { $0.matches(destination) }?.gateway ?? destination
    }

    private func nextHopV6(for destination: Data) -> Data {
        routesV6.first { $0.matches(destination) }?.gateway ?? destination
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

    private static func ipOnly(_ cidr: String) -> String {
        String(cidr.split(separator: "/", maxSplits: 1).first ?? "")
    }

    private static func networkCIDR(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return cidr }
        if cidr.contains("."), let ip = parseIPv4(String(parts[0])), prefix >= 0, prefix <= 32 {
            let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
            let network = ip & mask
            return "\((network >> 24) & 0xff).\((network >> 16) & 0xff).\((network >> 8) & 0xff).\(network & 0xff)/\(prefix)"
        }
        return cidr
    }

    private static func parseIPv4Route(_ value: String) -> IPv4Route? {
        let fields = value.split(separator: " ").map(String.init)
        guard let target = fields.first else { return nil }
        let parts = target.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let address = parseIPv4(String(parts[0])),
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
        let gatewayIndex = fields.firstIndex(of: "via").map { $0 + 1 }
        let gateway = gatewayIndex.flatMap { $0 < fields.count ? parseIPv4(ipOnly(fields[$0])) : nil }
        return IPv4Route(network: address, prefix: prefix, gateway: gateway)
    }

    private static func parseIPv6Route(_ value: String) -> IPv6Route? {
        let fields = value.split(separator: " ").map(String.init)
        guard let target = fields.first else { return nil }
        let parts = target.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let address = parseIPv6Data(String(parts[0])),
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else { return nil }
        let gatewayIndex = fields.firstIndex(of: "via").map { $0 + 1 }
        let gateway = gatewayIndex.flatMap { $0 < fields.count ? parseIPv6Data(ipOnly(fields[$0])) : nil }
        return IPv6Route(network: address, prefix: prefix, gateway: gateway)
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

private struct IPv4Route {
    let network: UInt32
    let prefix: Int
    let gateway: UInt32?

    func matches(_ address: UInt32) -> Bool {
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        return address & mask == network & mask
    }
}

private struct IPv6Route {
    let network: Data
    let prefix: Int
    let gateway: Data?

    func matches(_ address: Data) -> Bool {
        guard network.count == 16, address.count == 16 else { return false }
        let fullBytes = prefix / 8
        guard network.prefix(fullBytes) == address.prefix(fullBytes) else { return false }
        let remaining = prefix % 8
        guard remaining > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remaining)
        return network[fullBytes] & mask == address[fullBytes] & mask
    }
}
