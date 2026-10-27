import Foundation

/// Base45（RFC 9285 字母表）。字母表恰好是 QR alphanumeric 全集且不含 "|"，
/// 分片协议可以安全用 "|" 分隔。编解码两端都是本模块，自洽即可。
enum Base45 {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    private static let index: [Character: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    static func encode(_ data: Data) -> String {
        var out = String()
        out.reserveCapacity(data.count * 3 / 2 + 2)
        var i = data.startIndex
        while i < data.endIndex {
            let next = data.index(i, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
            if next == data.index(i, offsetBy: 1, limitedBy: data.endIndex)! {
                // 落单字节：两位
                let v = Int(data[i])
                out.append(alphabet[v % 45])
                out.append(alphabet[v / 45])
            } else {
                let v = Int(data[i]) << 8 | Int(data[data.index(after: i)])
                out.append(alphabet[v % 45])
                out.append(alphabet[(v / 45) % 45])
                out.append(alphabet[(v / 45) / 45])
            }
            i = next
        }
        return out
    }

    static func decode(_ string: String) -> Data? {
        let chars = Array(string)
        guard !chars.isEmpty else { return nil }
        var data = Data(capacity: chars.count * 2 / 3)
        var i = 0
        while i < chars.count {
            let remaining = chars.count - i
            if remaining >= 3 {
                guard let c = index[chars[i]], let d = index[chars[i + 1]],
                      let e = index[chars[i + 2]] else { return nil }
                let v = c + d * 45 + e * 2025
                guard v <= 0xFFFF else { return nil }
                data.append(UInt8(v >> 8))
                data.append(UInt8(v & 0xFF))
                i += 3
            } else if remaining == 2 {
                guard let c = index[chars[i]], let d = index[chars[i + 1]] else { return nil }
                let v = c + d * 45
                guard v <= 0xFF else { return nil }
                data.append(UInt8(v))
                i += 2
            } else {
                return nil // 编码不可能产生落单 1 字符
            }
        }
        return data
    }
}
