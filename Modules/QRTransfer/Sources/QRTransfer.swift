import Foundation
import CoreGraphics

/// 传输编解码入口。数据 → 压缩容器 → Base45 → 均匀分片（末帧补 '0' 对齐）→ 帧字符串数组。
public enum QRTransfer {
    static let magic = "ZTQR1"
    /// "ZTQR1|" + 2 + "|" + 2 + "|" + 8 + "|" + 5 + "|" = 27
    static let headerLen = magic.count + 1 + 2 + 1 + 2 + 1 + 8 + 1 + 5 + 1

    /// 屏幕可用边长（pt）→ 二维码模块数上限。模块 ≥ 2.5pt、quiet zone 4 模块、
    /// 硬顶 v25（117 模块）、下限 v9（53 模块）防极小屏。
    public static func recommendedMaxModules(side: CGFloat) -> Int {
        max(53, min(117, Int(side / 2.5) - 8))
    }

    public static func encode(_ data: Data, maxModules: Int = 117,
                              maxFrames: Int = 32) throws -> [String] {
        guard let container = Deflate.compress(data) else { throw QRTransferError.corrupt }
        let encoded = Base45.encode(container)
        guard let capacity = ChunkPlanner.capacity(payloadCount: encoded.count,
                                                   headerLen: headerLen,
                                                   maxModules: maxModules),
              capacity >= 1 else { throw QRTransferError.tooLarge }
        let frameCount = (encoded.count + capacity - 1) / capacity
        guard frameCount <= maxFrames else { throw QRTransferError.tooLarge }
        // 均匀分片：等宽 chunk；无法整除时补 '0' 对齐，
        // 全序列每帧字符数严格相等 → 二维码模块数一致
        let chunkSize = (encoded.count + frameCount - 1) / frameCount
        let crc = CRC32.checksum(data)
        let chars = Array(encoded)
        var frames: [String] = []
        var start = 0
        for i in 1...frameCount {
            let end = min(start + chunkSize, chars.count)
            var chunk = String(chars[start..<end])
            if chunk.count < chunkSize {
                chunk += String(repeating: "0", count: chunkSize - chunk.count)
            }
            frames.append("\(magic)|\(String(format: "%02d", frameCount))|"
                + "\(String(format: "%02d", i))|\(String(format: "%08x", crc))|"
                + "\(String(format: "%05d", encoded.count))|\(chunk)")
            start = end
        }
        return frames
    }

    public static func parse(_ text: String) -> QRFrame? {
        let parts = text.split(separator: "|", maxSplits: 5,
                               omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == magic else { return nil }
        guard parts[1].count == 2, parts[2].count == 2, parts[4].count == 5,
              let total = Int(parts[1]), let index = Int(parts[2]),
              let length = Int(parts[4]),
              total >= 1, index >= 1, index <= total,
              length >= 1, length <= 99_999,
              parts[3].count == 8,
              let crc = UInt32(parts[3], radix: 16) else { return nil }
        return QRFrame(total: total, index: index, checksum: crc,
                       length: length, payload: parts[5])
    }

    /// 帧集合齐全且 CRC 通过才返回数据。
    public static func decode(_ frames: [QRFrame]) throws -> Data {
        guard let first = frames.first else { throw QRTransferError.incomplete }
        let total = first.total
        guard frames.count == total,
              Set(frames.map(\.index)).count == total,
              frames.allSatisfy({ $0.total == total })
        else { throw QRTransferError.incomplete }
        // 校验和不一致说明帧混自不同文档，属数据损坏而非缺帧
        guard frames.allSatisfy({ $0.checksum == first.checksum })
        else { throw QRTransferError.corrupt }
        let joined = frames.sorted { $0.index < $1.index }.map(\.payload).joined()
        // 先按 len 剥掉末帧补位，再进 Base45/解压/CRC 三重校验
        guard joined.count >= first.length else { throw QRTransferError.corrupt }
        let trimmed = String(joined.prefix(first.length))
        guard let container = Base45.decode(trimmed),
              let data = Deflate.decompress(container),
              CRC32.checksum(data) == first.checksum
        else { throw QRTransferError.corrupt }
        return data
    }
}
