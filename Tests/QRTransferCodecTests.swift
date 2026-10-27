import XCTest

final class QRTransferCodecTests: XCTestCase {
    func testBase45KnownVectors() {
        XCTAssertEqual(Base45.encode(Data("AB".utf8)), "BB8")
        XCTAssertEqual(Base45.encode(Data("He".utf8)), "%69")
    }

    func testBase45RoundTrip() {
        // 覆盖奇偶长度与较长数据
        for size in [1, 2, 3, 31, 32, 100, 1024] {
            var data = Data()
            for i in 0..<size { data.append(UInt8((i * 7 + 13) % 256)) }
            XCTAssertEqual(Base45.decode(Base45.encode(data)), data)
        }
    }

    func testBase45RejectsBadInput() {
        XCTAssertNil(Base45.decode("abc|"))   // '|' 不在字母表
        XCTAssertNil(Base45.decode("A"))      // 落单 1 字符不合法
        XCTAssertNil(Base45.decode("::::"))   // 解出值 > 0xFFFF
    }

    func testCRC32KnownVectors() {
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testDeflateRoundTripAndContainer() throws {
        let data = Data(String(repeating: "planet", count: 200).utf8)
        let container = try XCTUnwrap(Deflate.compress(data))
        // 容器头 4 字节 = 原始长度小端
        XCTAssertEqual(UInt32(container[0]) | UInt32(container[1]) << 8
                       | UInt32(container[2]) << 16 | UInt32(container[3]) << 24,
                       UInt32(data.count))
        XCTAssertEqual(Deflate.decompress(container), data)
        XCTAssertNil(Deflate.decompress(Data([0, 0, 0, 0])))
    }
}
