import XCTest

final class QRTransferFrameTests: XCTestCase {
    private func sampleData(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(($0 * 31 + 7) % 256) })
    }

    /// xorshift 伪随机字节，近不可压缩。sampleData 以 256 字节为周期，
    /// deflate 可压到几百字节，无法触发 tooLarge。
    private func noisyData(_ size: Int) -> Data {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return Data((0..<size).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
    }

    /// 探测串前缀必须携带真实帧头（等形等长），帧格式变更时两者失配会让容量密度保证静默失效
    func testProbePrefixMatchesHeaderLen() {
        XCTAssertEqual(ChunkPlanner.probePrefix.count, QRTransfer.headerLen)
    }

    func testSingleFrameRoundTrip() throws {
        let data = sampleData(300)
        let frames = try QRTransfer.encode(data, maxModules: 117)
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(QRRender.fits(frames[0], maxModules: 117))
        XCTAssertEqual(try QRTransfer.decode(frames.compactMap(QRTransfer.parse)), data)
    }

    func testMultiFrameUniformPaddedAndRestored() throws {
        let data = sampleData(2000)
        // 53 模块（v9）小容量强制多帧
        let frames = try QRTransfer.encode(data, maxModules: 53)
        XCTAssertGreaterThan(frames.count, 1)
        // 每帧数据段字符数严格相等（无法整除时末帧补 '0' 对齐）
        let chunkLens = Set(frames.map {
            $0.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)[5].count
        })
        XCTAssertEqual(chunkLens.count, 1)
        // 每一帧真实形态都不得超过容量上限（探测失真回归防护）
        for frame in frames {
            XCTAssertTrue(QRRender.fits(frame, maxModules: 53),
                          "帧超出 53 模块：长度 \(frame.count) 字符")
        }
        // 剥补位后完整还原
        XCTAssertEqual(try QRTransfer.decode(frames.compactMap(QRTransfer.parse)), data)
    }

    func testTooLargeThrows() {
        XCTAssertThrowsError(try QRTransfer.encode(noisyData(200_000), maxModules: 53)) {
            XCTAssertEqual($0 as? QRTransferError, .tooLarge)
        }
    }

    func testParseRejectsBadInput() {
        XCTAssertNil(QRTransfer.parse("hello world"))
        XCTAssertNil(QRTransfer.parse("ZTQR1|02|03|deadbeef|00123|xx")) // index > total
        XCTAssertNil(QRTransfer.parse("ZTQR1|2|01|deadbeef|00123|xx"))  // 位数不足
        XCTAssertNil(QRTransfer.parse("ZTQR1|02|01|deadbeef|0123|xx"))  // len 位数不足
    }

    func testDecodeDetectsMissingAndCorrupt() throws {
        let data = sampleData(500)
        let frames = try QRTransfer.encode(data, maxModules: 53)
        let parsed = frames.compactMap(QRTransfer.parse)
        // 缺帧 → incomplete
        XCTAssertThrowsError(try QRTransfer.decode(Array(parsed.dropLast()))) {
            XCTAssertEqual($0 as? QRTransferError, .incomplete)
        }
        // 篡改校验和 → corrupt（CRC 兜底拦截）
        let tampered = QRFrame(total: parsed[0].total, index: parsed[0].index,
                               checksum: 0, length: parsed[0].length,
                               payload: parsed[0].payload)
        XCTAssertThrowsError(try QRTransfer.decode(parsed.dropFirst() + [tampered])) {
            XCTAssertEqual($0 as? QRTransferError, .corrupt)
        }
    }
}
