import Foundation

/// IPv4 ARP 表（IP 统一 host order）——移植 Android service/ARPTable.java
final class ARPTable {
    private var map: [UInt32: UInt64] = [:]   // IPv4(host order) -> MAC
    private let lock = NSLock()

    func lookup(_ ip: UInt32) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return map[ip]
    }

    func update(_ ip: UInt32, mac: UInt64) {
        lock.lock(); defer { lock.unlock() }
        map[ip] = mac
    }

    // MARK: - 报文构造/解析（RFC 826，字段大端；对齐 Android ARPReplyData 的字节布局）

    static func request(senderIP: UInt32, senderMAC: UInt64, targetIP: UInt32) -> Data {
        var p = Data(capacity: 28)
        p.append(contentsOf: [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01])
        appendMAC(&p, senderMAC); appendIP(&p, senderIP)
        appendMAC(&p, 0);         appendIP(&p, targetIP)
        return p
    }

    static func reply(senderIP: UInt32, senderMAC: UInt64, targetIP: UInt32, targetMAC: UInt64) -> Data {
        var p = Data(capacity: 28)
        p.append(contentsOf: [0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x02])
        appendMAC(&p, senderMAC); appendIP(&p, senderIP)
        appendMAC(&p, targetMAC); appendIP(&p, targetIP)
        return p
    }

    struct Packet {
        var op: UInt16        // 1 请求 2 应答
        var senderMAC: UInt64
        var senderIP: UInt32  // host order
        var targetMAC: UInt64
        var targetIP: UInt32  // host order
    }

    static func parse(_ payload: Data) -> Packet? {
        guard payload.count >= 28,
              payload[0] == 0, payload[1] == 1,
              payload[2] == 0x08, payload[3] == 0 else { return nil }
        func mac(_ o: Int) -> UInt64 { (0..<6).reduce(UInt64(0)) { ($0 << 8) | UInt64(payload[o + $1]) } }
        func ip(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(payload[o + $1]) } }
        return Packet(op: (UInt16(payload[6]) << 8) | UInt16(payload[7]),
                      senderMAC: mac(8), senderIP: ip(14),
                      targetMAC: mac(18), targetIP: ip(24))
    }

    private static func appendMAC(_ p: inout Data, _ m: UInt64) {
        for shift in stride(from: 40, through: 0, by: -8) { p.append(UInt8((m >> UInt64(shift)) & 0xff)) }
    }
    private static func appendIP(_ p: inout Data, _ ip: UInt32) {
        p.append(UInt8((ip >> 24) & 0xff)); p.append(UInt8((ip >> 16) & 0xff))
        p.append(UInt8((ip >> 8) & 0xff));  p.append(UInt8(ip & 0xff))
    }
}
