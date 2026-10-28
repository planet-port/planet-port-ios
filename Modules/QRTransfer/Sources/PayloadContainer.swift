import Foundation

/// ZTP KV 容器（载荷层 wire format）。容器 = magic "ZTP" + 无序条目流，
/// 条目 = key(1B) + len(4B 小端) + value，数据尾即容器尾。
/// 纯字节层编解码，对 key 含义零假设——key 语义是应用层约定，
/// 未知 key 由解析方自行忽略，保证 wire format 永不随业务演进变化。
public enum PayloadContainer {
    static let magic = "ZTP"
    /// 0 保留为非法哨兵
    static let invalidKey: UInt8 = 0

    /// 字段列表 → 容器。key 为 0 的字段直接丢弃；同 key 多条目时 decode
    /// 取后值，编码方应避免产生重复。空列表产出仅含 magic 的合法空容器。
    public static func encode(_ fields: [(key: UInt8, value: Data)]) -> Data {
        var out = Data(magic.utf8)
        for field in fields where field.key != invalidKey {
            out.append(field.key)
            withUnsafeBytes(of: UInt32(field.value.count).littleEndian) {
                out.append(contentsOf: $0)
            }
            out.append(field.value)
        }
        return out
    }

    /// 容器 → 字典。magic 不符、key 为 0、len 越界（截断/损坏）→ nil；
    /// 重复 key 取后出现的值（字典赋值天然覆盖）。
    public static func decode(_ data: Data) -> [UInt8: Data]? {
        let start = data.startIndex
        guard data.count >= magic.count,
              String(data: data.subdata(in: start..<data.index(start, offsetBy: magic.count)),
                     encoding: .ascii) == magic else { return nil }
        var fields: [UInt8: Data] = [:]
        var i = data.index(start, offsetBy: magic.count)
        while i < data.endIndex {
            let key = data[i]
            guard key != invalidKey else { return nil }
            let lenIndex = data.index(after: i)
            guard data.distance(from: lenIndex, to: data.endIndex) >= 4 else { return nil }
            let len = Int(data[lenIndex])
                | Int(data[data.index(after: lenIndex)]) << 8
                | Int(data[data.index(lenIndex, offsetBy: 2)]) << 16
                | Int(data[data.index(lenIndex, offsetBy: 3)]) << 24
            let valueStart = data.index(lenIndex, offsetBy: 4)
            guard data.distance(from: valueStart, to: data.endIndex) >= len else { return nil }
            fields[key] = data.subdata(in: valueStart..<data.index(valueStart, offsetBy: len))
            i = data.index(valueStart, offsetBy: len)
        }
        return fields
    }
}
