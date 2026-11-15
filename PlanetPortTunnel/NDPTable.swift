import Foundation

/// IPv6 邻居发现表（NS/NA 软件处理）。出站报文按 RFC 4861 布局构造，ICMPv6
/// 伪头校验和按 RFC 4443/1071 计算回写（恒 0 会被真实节点内核丢弃）；NA 分
/// 单播 Solicited 与 DAD 全节点组播两种形态（RFC 4861 §7.2.4）。
final class NDPTable {
    private var map: [Data: UInt64] = [:]   // 16 字节 IPv6 地址 -> MAC
    private let lock = NSLock()

    func lookup(_ v6: Data) -> UInt64? {
        precondition(v6.count == 16)
        lock.lock(); defer { lock.unlock() }
        return map[v6]
    }

    func update(_ v6: Data, mac: UInt64) {
        precondition(v6.count == 16)
        lock.lock(); defer { lock.unlock() }
        map[v6] = mac
    }

    /// 表项数（诊断展示）
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    // MARK: - ICMPv6 NS/NA 报文构造

    /// 邻居请求载荷（type 135）：头(4)+flags/保留(4)+target(16)+源 MAC 选项(8) 共 32 字节
    static func neighborSolicitation(target: Data, senderMAC: UInt64) -> Data {
        icmpv6(type: 135, flags: 0, target: target, mac: senderMAC)
    }

    /// 邻居通告载荷（type 136）。solicited = true：Solicited+Override 置位
    /// （0x60，应答已知请求方的单播形态）；false：仅 Override（0x20，DAD 探测的
    /// 全节点组播形态，RFC 4861 §7.2.4——组播受众不做 Solicited 置位）。
    static func neighborAdvertisement(target: Data, senderMAC: UInt64, solicited: Bool = true) -> Data {
        icmpv6(type: 136, flags: solicited ? 0x60 : 0x20, target: target, mac: senderMAC)
    }

    /// 全节点组播地址 ff02::1（DAD 应答的目的地址，RFC 4861 §7.2.4）
    static let allNodesMulticast: Data = {
        var b = [UInt8](repeating: 0, count: 16)
        b[1] = 0x02; b[15] = 0x01
        return Data(b)
    }()

    /// 是否未指定地址 ::（DAD 探测的 NS 源形态）
    static func isUnspecified(_ addr: Data) -> Bool {
        addr.allSatisfy { $0 == 0 }
    }

    /// ICMPv6 伪头校验和（RFC 4443 §8.1）：src(16B)+dst(16B)+载荷长度(32bit)+
    /// 3 零字节+nextHeader(58)，与载荷一起按 RFC 1071 互联网校验和求和，取反
    /// 回写 payload[2..3]。计算前先清零校验和字段。真实节点内核会校验，恒 0
    /// 的报文被丢弃（纯软件对端不校验，故缺陷此前未暴露）。
    static func icmpv6Checksum(src: Data, dst: Data, payload: inout Data) {
        precondition(src.count == 16 && dst.count == 16 && payload.count >= 4)
        payload[2] = 0; payload[3] = 0
        var sum: UInt32 = 0
        func add16(_ word: UInt16) { sum &+= UInt32(word) }
        for i in stride(from: 0, to: 16, by: 2) {
            add16((UInt16(src[i]) << 8) | UInt16(src[i + 1]))
        }
        for i in stride(from: 0, to: 16, by: 2) {
            add16((UInt16(dst[i]) << 8) | UInt16(dst[i + 1]))
        }
        add16(UInt16(payload.count))  // 伪头 32bit 长度的高 16 位恒 0，单字相加等价
        add16(58)                     // next header = ICMPv6
        var i = 0
        while i < payload.count {
            let hi = UInt16(payload[i])
            let lo = i + 1 < payload.count ? UInt16(payload[i + 1]) : 0
            add16((hi << 8) | lo)
            i += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let ck = UInt16((~sum) & 0xffff)
        payload[2] = UInt8(ck >> 8)
        payload[3] = UInt8(ck & 0xff)
    }

    /// IPv6 组播地址对应的组播 MAC（前缀 0x3333 + 地址低 32 位）
    static func multicastMAC(for v6: Data) -> UInt64 {
        precondition(v6.count == 16)
        let b = [UInt8](v6)
        return 0x333300000000
            | (UInt64(b[12]) << 24) | (UInt64(b[13]) << 16)
            | (UInt64(b[14]) << 8) | UInt64(b[15])
    }

    /// 目标地址的请求节点组播地址（ff02::1:ffXX:XXXX）
    static func solicitedNodeMulticast(target: Data) -> Data {
        precondition(target.count == 16)
        let t = [UInt8](target)
        var m = [UInt8](repeating: 0, count: 16)
        m[0] = 0xff; m[1] = 0x02
        m[11] = 0x01; m[12] = 0xff
        m[13] = t[13]; m[14] = t[14]; m[15] = t[15]
        return Data(m)
    }

    /// RFC 4861 布局：ICMPv6 头(4) + flags/保留(4) + target(16) + 链路层地址选项(8，类型按报文分派)，与 parse 对齐
    private static func icmpv6(type: UInt8, flags: UInt8, target: Data, mac: UInt64) -> Data {
        var p = [UInt8](repeating: 0, count: 32)
        p[0] = type; p[1] = 0
        p[2] = 0; p[3] = 0        // 校验和字段，icmpv6Checksum 回写
        p[4] = flags              // NS 恒 0；NA 见 neighborAdvertisement 的 Solicited/Override 语义
        p.replaceSubrange(8..<24, with: [UInt8](target))
        // 选项类型按报文分派（RFC 4861 §4.6.1/§4.6.2）：NS 携带源链路层地址选项
        // （type 1），NA 携带目标链路层地址选项（type 2）——真实内核 ndisc 只按
        // 各自类型读取选项，类型错配的报文被丢弃（对端解析永远 INCOMPLETE）
        p[24] = type == 136 ? 2 : 1; p[25] = 1
        for shift in stride(from: 40, through: 0, by: -8) {
            p[26 + (5 - shift / 8)] = UInt8((mac >> UInt64(shift)) & 0xff)
        }
        return Data(p)
    }

    struct Packet {
        var type: UInt8     // 135 NS / 136 NA
        var target: Data    // 16 字节
        var senderMAC: UInt64?
    }

    /// 解析 ICMPv6 NS/NA 载荷（IPv6 头后）。链路层地址选项类型按报文分派：
    /// NS 认源选项（1），NA 认目标选项（2）。入站不校验校验和字段——与带校验和
    /// 的对端报文及不校验的软件路径天然兼容
    static func parse(_ payload: Data) -> Packet? {
        guard payload.count >= 24, payload[0] == 135 || payload[0] == 136 else { return nil }
        let target = payload.subdata(in: 8..<24)
        var senderMAC: UInt64?
        if payload.count >= 32, payload[25] == 1 {
            // 选项类型按报文分派：NS=源选项(1)、NA=目标选项(2)；NA 宽限也收 1，
            // 兼容仍按旧构造（未修复）发 type 1 的软件姊妹端
            let accepted: Set<UInt8> = payload[0] == 136 ? [2, 1] : [1]
            if accepted.contains(payload[24]) {
                senderMAC = (2..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(payload[24 + $1]) }
            }
        }
        return Packet(type: payload[0], target: target, senderMAC: senderMAC)
    }

    /// 是否为 NDP 报文（完整 IPv6 包：next header 58 = ICMPv6 且 type 135/136）
    static func isNDP(ipv6Packet: Data) -> Bool {
        guard ipv6Packet.count >= 48 else { return false }
        guard ipv6Packet[6] == 58 else { return false }  // next header = ICMPv6
        let t = ipv6Packet[40]
        return t == 135 || t == 136
    }
}
