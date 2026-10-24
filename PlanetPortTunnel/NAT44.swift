import Foundation

// MARK: - 多网络源地址 NAT

/// iOS 单 tun 多地址时源地址选错（总选接口主地址）的系统级缺陷修复。
/// NEIPv4Route 无源地址绑定、无 per-route src，路由层无出路，只能在数据面改包：
/// - 出站：源 IP 不属于所选网络时改写为该网络地址（增量修正 IP 头与 TCP/UDP 校验和），
///   TCP/UDP 登记流表（proto + 远端 IP/端口 + 本地端口 → 原始源）
/// - 入站：命中流表的回包把目的地址回写为原始源——否则内核 socket
///   （本地地址是错误的原始源）匹配不上，TCP 握手无法完成
/// - ICMP 无需回写：echo 回包按 id 匹配 raw socket，不按目的地址；
///   ICMP 差错报文（嵌入的原包头源已是改写后地址）无法送回原始 socket，是已知限制
/// - 分片包不进流表（非首片无端口无法匹配；ZT 内部 MTU 内基本不分片，维持现状）
/// - 单网络场景源不可能错，零改动直通，不引入回归
/// 线程：无锁，仅在 FrameConverter 的锁内使用。
final class NAT44 {

    /// TCP=6 / UDP=17，nwid + 四元组流键（不换端口，纯地址改写）。
    /// 带 nwid：嵌套子网（如 10.0.0.0/8 与 10.0.0.0/24 两网共存，冲突检测按
    /// CIDR 精确比较不拦）时同一四元组可能分属两网的不同流且原始源不同，
    /// 按网络隔离流键即根除串流。
    struct FlowKey: Hashable {
        let nwid: UInt64
        let proto: UInt8
        let remoteIP: UInt32   // host order
        let remotePort: UInt16
        let localPort: UInt16
    }

    private struct Entry {
        let origSrc: UInt32    // 手机内核实际选的源（另一网络地址）
        var lastUsed: Date
    }

    /// Network Extension 内存约束：上限 + LRU + 按协议空闲老化。
    /// TCP 拉长到小时级（对齐 conntrack established 思路：真实保活间隔均为分钟级，
    /// 空闲超时后"对端先发包"才断流，长连接场景（SSH/IMAP IDLE）需覆盖其空闲窗口）；
    /// UDP 无连接语义，短老化靠新出站重建。双向任一包都刷新活跃时间。
    static let maxEntries = 512
    static let idleTimeoutTCP: TimeInterval = 6 * 3600
    static let idleTimeoutUDP: TimeInterval = 60

    private var flows: [FlowKey: Entry] = [:]

    /// 表项数（诊断输出用）
    var count: Int { flows.count }

    /// 出站登记/刷新（改写源前调用）
    func record(_ key: FlowKey, origSrc: UInt32) {
        if flows[key] != nil {
            flows[key]?.lastUsed = Date()
            return
        }
        if flows.count >= Self.maxEntries { evictLocked() }
        flows[key] = Entry(origSrc: origSrc, lastUsed: Date())
    }

    /// 入站查询（命中即刷新活跃时间）
    func lookup(_ key: FlowKey) -> UInt32? {
        guard var e = flows[key] else { return nil }
        e.lastUsed = Date()
        flows[key] = e
        return e.origSrc
    }

    /// 清理：先淘汰过期（按各流协议老化时间），仍满则逐最旧（512 条 O(n) 可忽略）
    private func evictLocked() {
        let now = Date()
        flows = flows.filter { now.timeIntervalSince($0.value.lastUsed) < timeout(of: $0.key) }
        while flows.count >= Self.maxEntries {
            guard let oldest = flows.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
            flows.removeValue(forKey: oldest.key)
        }
    }

    private func timeout(of key: FlowKey) -> TimeInterval {
        key.proto == 6 ? Self.idleTimeoutTCP : Self.idleTimeoutUDP
    }

    // MARK: - 出站流键提取

    /// 从出站 IPv4 包提取 TCP/UDP 流键；非 TCP/UDP 或分片返回 nil（ICMP 无需流表）
    static func outboundKey(_ pkt: Data, nwid: UInt64) -> FlowKey? {
        guard pkt.count >= 24, pkt[0] >> 4 == 4 else { return nil }
        let proto = pkt[9]
        guard proto == 6 || proto == 17 else { return nil }
        guard !isFragment(pkt) else { return nil }
        let ihl = Int(pkt[0] & 0x0f) * 4
        guard pkt.count >= ihl + 4 else { return nil }
        return FlowKey(nwid: nwid, proto: proto,
                       remoteIP: FrameConverter.bigEndianIP32(pkt, 16),
                       remotePort: port(pkt, ihl + 2),
                       localPort: port(pkt, ihl))
    }

    /// 从入站 IPv4 包提取流键（方向翻转：对端为源）；非 TCP/UDP 或分片返回 nil
    static func inboundKey(_ pkt: Data, nwid: UInt64) -> FlowKey? {
        guard pkt.count >= 24, pkt[0] >> 4 == 4 else { return nil }
        let proto = pkt[9]
        guard proto == 6 || proto == 17 else { return nil }
        guard !isFragment(pkt) else { return nil }
        let ihl = Int(pkt[0] & 0x0f) * 4
        guard pkt.count >= ihl + 4 else { return nil }
        return FlowKey(nwid: nwid, proto: proto,
                       remoteIP: FrameConverter.bigEndianIP32(pkt, 12),
                       remotePort: port(pkt, ihl),
                       localPort: port(pkt, ihl + 2))
    }

    /// MF 位置位或片偏移非零（首 4 位以外的 flags+fragment 全域）
    private static func isFragment(_ pkt: Data) -> Bool {
        ((UInt16(pkt[6]) << 8) | UInt16(pkt[7])) & 0x3fff != 0
    }

    /// 片偏移（8 字节单位，首片为 0）
    private static func fragOffset(_ pkt: Data) -> UInt16 {
        (((UInt16(pkt[6]) << 8) | UInt16(pkt[7])) & 0x1fff)
    }

    private static func port(_ pkt: Data, _ o: Int) -> UInt16 {
        (UInt16(pkt[o]) << 8) | UInt16(pkt[o + 1])
    }

    // MARK: - 地址改写（校验和按 RFC 1624 增量修正）

    /// 改写 IPv4 包 offset 处地址（12=源 / 16=目的），增量修正 IP 头与 L4 校验和。
    /// 非首片分片（片偏移≠0）只修 IP 头——其 ihl 之后是用户载荷不是 L4 头，
    /// 按 L4 校验和位置写回会破坏载荷；首片（MF=1 且偏移 0）含完整 L4 头可全量修正。
    /// 调用方保证 v4、地址确实位于 offset。
    static func rewriteAddress(_ pkt: inout Data, offset: Int, old: UInt32, new: UInt32) {
        guard pkt.count >= 20 else { return }
        adjustChecksum(&pkt, ckOffset: 10, old: old, new: new)
        write32(&pkt, offset, new)
        if fragOffset(pkt) != 0 { return }
        let ihl = Int(pkt[0] & 0x0f) * 4
        switch pkt[9] {
        case 6:  // TCP 校验和在 ihl+16
            adjustChecksum(&pkt, ckOffset: ihl + 16, old: old, new: new)
        case 17: // UDP 校验和在 ihl+6；0 表示未计算（卸载），保持
            guard pkt.count >= ihl + 8, !(pkt[ihl + 6] == 0 && pkt[ihl + 7] == 0) else { return }
            adjustChecksum(&pkt, ckOffset: ihl + 6, old: old, new: new, zeroAsFFFF: true)
        default: // ICMP 校验和不覆盖 IP 地址，无需修正
            break
        }
    }

    /// RFC 1624: HC' = ~(~HC + ~m + m')，反码进位回卷
    private static func adjustChecksum(_ pkt: inout Data, ckOffset: Int, old: UInt32, new: UInt32,
                                       zeroAsFFFF: Bool = false) {
        guard pkt.count >= ckOffset + 2 else { return }
        let hc = UInt16(pkt[ckOffset]) << 8 | UInt16(pkt[ckOffset + 1])
        let m = ocAdd(UInt16(old >> 16), UInt16(old & 0xffff))
        let mp = ocAdd(UInt16(new >> 16), UInt16(new & 0xffff))
        var sum = UInt32(~hc & 0xffff)
        sum &+= UInt32(~m & 0xffff)
        sum &+= UInt32(mp)
        while sum > 0xffff { sum = (sum & 0xffff) + (sum >> 16) }
        var result = ~UInt16(sum)
        if zeroAsFFFF && result == 0 { result = 0xffff }  // RFC 768：计算值为 0 传 0xffff
        pkt[ckOffset] = UInt8(result >> 8)
        pkt[ckOffset + 1] = UInt8(result & 0xff)
    }

    /// 反码加法（端回卷进位）
    private static func ocAdd(_ a: UInt16, _ b: UInt16) -> UInt16 {
        var s = UInt32(a) + UInt32(b)
        while s > 0xffff { s = (s & 0xffff) + (s >> 16) }
        return UInt16(s)
    }

    private static func write32(_ pkt: inout Data, _ offset: Int, _ v: UInt32) {
        pkt[offset] = UInt8(v >> 24)
        pkt[offset + 1] = UInt8(v >> 16 & 0xff)
        pkt[offset + 2] = UInt8(v >> 8 & 0xff)
        pkt[offset + 3] = UInt8(v & 0xff)
    }
}
