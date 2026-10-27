import Foundation
import Compression

/// 压缩容器：4 字节小端原始长度 + raw deflate（COMPRESSION_ZLIB 即 raw deflate 流）。
/// 自带长度使得解压侧可以直接分配目标缓冲，不依赖外部传尺寸。
enum Deflate {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(capacity: data.count + 16)
        let len = UInt32(data.count).littleEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        // 不可压缩数据的膨胀上界（块开销）给足余量
        let dstCap = data.count + data.count / 64 + 64
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
            defer { dst.deallocate() }
            let n = compression_encode_buffer(dst, dstCap,
                                              src.bindMemory(to: UInt8.self).baseAddress!,
                                              data.count, nil, COMPRESSION_ZLIB)
            guard n > 0 else { return nil }
            out.append(dst, count: n)
            return out
        }
    }

    static func decompress(_ container: Data) -> Data? {
        guard container.count > 4 else { return nil }
        let len = UInt32(container[container.startIndex])
            | UInt32(container[container.startIndex + 1]) << 8
            | UInt32(container[container.startIndex + 2]) << 16
            | UInt32(container[container.startIndex + 3]) << 24
        guard len > 0, len < 16 * 1024 * 1024 else { return nil }
        let body = container.dropFirst(4)
        return body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(len))
            defer { dst.deallocate() }
            let n = compression_decode_buffer(dst, Int(len),
                                              src.bindMemory(to: UInt8.self).baseAddress!,
                                              body.count, nil, COMPRESSION_ZLIB)
            guard n == Int(len) else { return nil }
            return Data(bytes: dst, count: n)
        }
    }
}
