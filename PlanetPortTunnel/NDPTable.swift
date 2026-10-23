import Foundation

/// IPv6 邻居发现表——移植 Android service/NDPTable.java 语义（NS/NA 软件处理）
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

    // MARK: - ICMPv6 NS/NA 报文构造

    /// 邻居请求（ICMPv6 type 135）：目标地址的请求节点组播地址
    static func neighborSolicitation(target: Data, senderMAC: UInt64, senderIPv6: Data?) -> Data {
        icmpv6(type: 135, code: 0, target: target, extra: macOption(senderMAC), includeSolicited: false)
    }

    /// 邻居通告（ICMPv6 type 136，Solicited+Override 置位）
    static func neighborAdvertisement(target: Data, senderMAC: UInt64, senderIPv6: Data?) -> Data {
        icmpv6(type: 136, code: 0, target: target, extra: macOption(senderMAC), includeSolicited: true)
    }

    /// IPv6 组播地址对应的组播 MAC（前缀 0x3333 + 地址低 32 位，
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

    private static func macOption(_ mac: UInt64) -> Data {
        // 源链路层地址选项：type=1, len=1(8字节), MAC
        var o = Data([1, 1])
        for shift in stride(from: 40, through: 0, by: -8) { o.append(UInt8((mac >> UInt64(shift)) & 0xff)) }
        return o
    }

    private static func icmpv6(type: UInt8, code: UInt8, target: Data, extra: Data, includeSolicited: Bool) -> Data {
        var p = Data()
        p.append(type); p.append(code)
        p.append(UInt8(includeSolicited ? 0x60 : 0x00)); p.append(0) // Solicited|Override 或 0
        p.append(target)   // 16 字节目标地址
        p.append(extra)
        return p
    }

    struct Packet {
        var type: UInt8     // 135 NS / 136 NA
        var target: Data    // 16 字节
        var senderMAC: UInt64?
    }

    /// 解析 ICMPv6 NS/NA 载荷（IPv6 头后）
    static func parse(_ payload: Data) -> Packet? {
        guard payload.count >= 24, payload[0] == 135 || payload[0] == 136 else { return nil }
        let target = payload.subdata(in: 8..<24)
        var senderMAC: UInt64?
        if payload.count >= 32, payload[24] == 1, payload[25] == 1 {
            senderMAC = (2..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(payload[24 + $1]) }
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
