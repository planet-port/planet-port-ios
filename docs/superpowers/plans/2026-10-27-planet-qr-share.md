# 动态二维码分享/导入 Planet 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 自定义 planet 通过动态二维码（分片轮播）在两台设备间点对点传输：分享端展示分片序列（可调速/手动），接收端连续扫码聚合、校验完整后自动完成导入。

**Architecture:** 传输逻辑做成零依赖 App 的独立模块 `Modules/QRTransfer`（后期开源为 pod）：数据 → zlib 压缩 → Base45 → 均匀分片 → 每帧 `ZTQR1|total|index|crc32|chunk` 协议字符串 → CIQRCodeGenerator 生成二维码（模块数按屏幕自适应、硬顶 v25）。App 侧只有两个接入点：新增行星表单的"或动态二维码导入"按钮（接收端）、行星设置页的二维码分享入口（发送端，仅自定义行星）。

**Tech Stack:** Swift / SwiftUI / AVFoundation（连续扫码）/ Compression（raw deflate）/ CoreImage（CIQRCodeGenerator）。不引入第三方依赖。

## Global Constraints

- **不写测试用例**（用户全局规则 7.1）。每任务验证 = `xcodegen generate` + `xcodebuild` 编译通过。
- 模块代码 **禁止 import 任何 App 代码**（ThemeManager / AppState / loc() / AppGroup 等一概不用），只用系统框架——为开源 pod 做准备。
- 模块 UI 文案走模块自有的 `QRTransfer.xcstrings`（表名 `QRTransfer`，三语 zh-Hans/zh-Hant/en），App 接入文案走 App 的 `Localizable.xcstrings`。
- 帧协议：`ZTQR1|<total 2位十进制>|<index 2位，1起>|<crc32 8位hex，原始数据的CRC>|<len 5位十进制，Base45全长>|<base45分片>`。单帧即 total=1，发送端退化为静态码、无任何控件。
- 分片均匀：`frameCount = ceil(n/容量)`，`chunkSize = ceil(n/frameCount)`；无法整除时**末帧（及各帧）统一补 '0' 到 chunkSize**，全序列每帧字符数严格相等 → 二维码模块数一致；接收端按 len 字段 `prefix(len)` 剥掉补位。
- **测试要求（用户明确要求写测试）**：模块纯逻辑（Base45/CRC32/Deflate/帧协议）必须有 XCTest 用例；测试 target `PlanetPortTests` 直接把 `Modules/QRTransfer/Sources` 编入自身模块（internal 符号可直接访问）。UI 层不写测试。
- 自适应上限：二维码模块数 ≤ `min(117, 可用边长pt/2.5 - 8)`，帧数上限 32，超出报"数据过大"。容量探测用真实 CIQRCodeGenerator 二分实测，不内嵌容量表。
- 接收端不区分单帧/多帧：永远走"解码帧 → 按 index 聚合 → 齐了才 CRC 校验 → 完整即回调"的同一条流水线；CRC 失败清空重来。
- 接收完成后数据回到 `AddPlanetForm` 的 `pendingData` 路径，复用现有"命名+添加+查重"流程。
- Base45 字母表不含 `|`，协议用 `|` 分隔安全。
- git 提交：中文 Conventional Commits，必须有 Body，禁止 Co-Authored-By。分支 `feat/planet-qr-share`（已创建，基于 dev）。
- 不分享官方 planet：行星设置页分享入口仅 `!isOfficial` 时出现。

---

### Task 1: 模块骨架接入工程 + 编解码原语（Base45 / CRC32 / Deflate）

**Files:**
- Create: `Modules/QRTransfer/Sources/BundleLocator.swift`
- Create: `Modules/QRTransfer/Sources/Base45.swift`
- Create: `Modules/QRTransfer/Sources/CRC32.swift`
- Create: `Modules/QRTransfer/Sources/Deflate.swift`
- Create: `Modules/QRTransfer/Resources/QRTransfer.xcstrings`（先建空表，Task 4 填全）
- Create: `Tests/QRTransferCodecTests.swift`
- Modify: `project.yml:23-25`（主 target sources 增加 Modules/QRTransfer）、`project.yml` targets 增加 PlanetPortTests、`project.yml:110-114` scheme 增加 test action

**Interfaces:**
- Produces（后续任务依赖的确切签名）:
  - `enum Base45 { static func encode(_ data: Data) -> String; static func decode(_ string: String) -> Data? }`
  - `enum CRC32 { static func checksum(_ data: Data) -> UInt32 }`
  - `enum Deflate { static func compress(_ data: Data) -> Data?; static func decompress(_ container: Data) -> Data? }`（compress 输出 = 4 字节小端原始长度 + raw deflate；decompress 校验长度）

- [ ] **Step 1: project.yml 增加模块路径、测试 target 与 test action**

`project.yml` 第 23-25 行 sources 改为：

```yaml
    sources:
      - path: PlanetPort
      - path: Shared
      - path: Modules/QRTransfer
```

`project.yml` 顶层 `targets:` 内（与 PlanetPort/PlanetPortTunnel 同级）追加测试 target：

```yaml
  PlanetPortTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "17.0"
    sources:
      - path: Tests
      - path: Modules/QRTransfer/Sources
    dependencies:
      - target: PlanetPort
```

> 测试 target 直接编入 `Modules/QRTransfer/Sources`，模块 internal 符号在测试模块内可直接访问，无需 `@testable import`。

`project.yml:110` schemes 段改为：

```yaml
schemes:
  PlanetPort:
    build:
      targets:
        PlanetPort: all
    test:
      targets:
        - PlanetPortTests
```

- [ ] **Step 2: 写 BundleLocator.swift**

```swift
import Foundation

/// 模块内本地化：表名 QRTransfer，bundle 定位到本模块目录。
/// 编进 App 或未来打成 pod（resource_bundles）两种形态都生效。
private final class QRTransferBundleLocator {}

extension Bundle {
    static var qrTransfer: Bundle { Bundle(for: QRTransferBundleLocator.self) }
}

/// 取模块文案。返回 String（已解析），配 Text(String) 或 String(format:) 使用。
func ql(_ key: String) -> String {
    NSLocalizedString(key, tableName: "QRTransfer", bundle: .qrTransfer,
                      value: key, comment: "")
}
```

- [ ] **Step 3: 写 Base45.swift**

```swift
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
```

- [ ] **Step 4: 写 CRC32.swift**

```swift
import Foundation

/// 标准 CRC-32（IEEE 802.3，反射多项式 0xEDB88320）。查表由代码生成，不硬编码 256 项。
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
```

- [ ] **Step 5: 写 Deflate.swift**

```swift
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
```

- [ ] **Step 6: 建空 xcstrings**

`Modules/QRTransfer/Resources/QRTransfer.xcstrings`：

```json
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {

  },
  "version" : "1.0"
}
```

- [ ] **Step 7: 写 Tests/QRTransferCodecTests.swift**

```swift
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
```

- [ ] **Step 8: 编译并跑测试**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
xcodegen generate
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'generic/platform=iOS Simulator' -quiet build
xcodebuild test -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet
```

Expected: `** BUILD SUCCEEDED **` 且 `Test Suite ... passed`（新文件被 XcodeGen glob 进 target；.xcstrings 自动归为资源）。

- [ ] **Step 9: Commit**

```bash
git add Modules/QRTransfer Tests project.yml PlanetPort.xcodeproj
git commit -m "feat(qrtransfer): 新增二维码传输模块骨架与编解码原语"
```

Body 说明：为动态二维码分享建立独立模块目录（后期开源 pod），本次纳入 Base45/CRC32/压缩容器三个纯算法原语并接入主 target，配套单测 target 与编解码用例。

---

### Task 2: 帧协议 + 自适应分片规划 + 二维码渲染

**Files:**
- Create: `Modules/QRTransfer/Sources/QRRender.swift`
- Create: `Modules/QRTransfer/Sources/QRFrame.swift`
- Create: `Modules/QRTransfer/Sources/ChunkPlanner.swift`
- Create: `Modules/QRTransfer/Sources/QRTransfer.swift`
- Create: `Tests/QRTransferFrameTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `Base45.encode/decode`、`CRC32.checksum`、`Deflate.compress/decompress`
- Produces:
  - `struct QRFrame { let total: Int; let index: Int; let checksum: UInt32; let length: Int; let payload: String }`（length = Base45 全长，剥补位用）
  - `enum QRTransferError: Error, Equatable { case tooLarge, incomplete, corrupt }`
  - `enum QRTransfer { static func encode(_ data: Data, maxModules: Int = 117, maxFrames: Int = 32) throws -> [String]; static func parse(_ text: String) -> QRFrame?; static func decode(_ frames: [QRFrame]) throws -> Data; static func recommendedMaxModules(side: CGFloat) -> Int }`
  - `enum QRRender { static func generate(_ text: String) -> (image: UIImage, modules: Int)?; static func fits(_ text: String, maxModules: Int) -> Bool }`

- [ ] **Step 1: 写 QRRender.swift**

```swift
import UIKit
import CoreImage

/// CIQRCodeGenerator 封装。输出 extent 宽 = 模块数（quiet zone 不计），
/// 用它做密度约束，不依赖内嵌容量表。
enum QRRender {
    private static func make(_ text: String) -> CIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        return filter.outputImage
    }

    /// 生成位图（scale 放大保证清晰）。返回模块数供密度判断。
    static func generate(_ text: String, scale: Int = 10) -> (image: UIImage, modules: Int)? {
        guard let output = make(text) else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cg = CIContext().createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return (UIImage(cgImage: cg), Int(output.extent.width))
    }

    /// 文本能否生成模块数 ≤ maxModules 的二维码（探测用，不出位图）。
    static func fits(_ text: String, maxModules: Int) -> Bool {
        guard let output = make(text) else { return false }
        return Int(output.extent.width) <= maxModules
    }
}
```

- [ ] **Step 2: 写 QRFrame.swift**

```swift
import Foundation

/// 单帧结构。text 即二维码内容：ZTQR1|total|index|crc32|len|chunk
/// total/index 为两位十进制（1..99，index 从 1 起），crc32 为原始数据的 CRC、
/// len 为 Base45 全长（真实字符数，每帧重复携带），均用于接收端自描述恢复。
public struct QRFrame: Equatable {
    let total: Int
    let index: Int
    let checksum: UInt32
    let length: Int
    /// Base45 分片字符串（末帧含补 '0' 对齐）
    let payload: String
}

public enum QRTransferError: Error, Equatable {
    case tooLarge
    case incomplete
    case corrupt
}
```

- [ ] **Step 3: 写 ChunkPlanner.swift**

```swift
import Foundation

/// 每帧容量探测：二分查找最大的"分片字符数"，
/// 使 定长协议头+该长度探测串 生成的二维码模块数 ≤ maxModules。
/// 探测串与真实分片同为 ASCII 且等长，编码行为一致，单调可二分。
enum ChunkPlanner {
    static func capacity(payloadCount: Int, headerLen: Int, maxModules: Int) -> Int? {
        var lo = 1
        var hi = max(payloadCount, 1)
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let probe = String(repeating: "0", count: headerLen + mid)
            if QRRender.fits(probe, maxModules: maxModules) {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
```

- [ ] **Step 4: 写 QRTransfer.swift**

```swift
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
              frames.allSatisfy({ $0.total == total && $0.checksum == first.checksum })
        else { throw QRTransferError.incomplete }
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
```

- [ ] **Step 5: 写 Tests/QRTransferFrameTests.swift**

```swift
import XCTest

final class QRTransferFrameTests: XCTestCase {
    private func sampleData(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(($0 * 31 + 7) % 256) })
    }

    func testSingleFrameRoundTrip() throws {
        let data = sampleData(300)
        let frames = try QRTransfer.encode(data, maxModules: 117)
        XCTAssertEqual(frames.count, 1)
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
        // 剥补位后完整还原
        XCTAssertEqual(try QRTransfer.decode(frames.compactMap(QRTransfer.parse)), data)
    }

    func testTooLargeThrows() {
        XCTAssertThrowsError(try QRTransfer.encode(sampleData(200_000), maxModules: 53)) {
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
```

- [ ] **Step 6: 编译并跑测试**（命令同 Task 1 Step 8）

Expected: `** BUILD SUCCEEDED **`，新增 5 个用例全绿。

- [ ] **Step 7: Commit**

```bash
git add Modules/QRTransfer Tests PlanetPort.xcodeproj
git commit -m "feat(qrtransfer): 实现帧协议与自适应分片规划"
```

Body 说明：定义 ZTQR1 帧格式（total/index/总CRC/Base45全长 每帧重复携带），用真实 CIQRCodeGenerator 二分探测每帧容量，等宽分片并在无法整除时末帧补 0 对齐，接收端按长度字段剥补位还原。

---

### Task 3: 连续扫码控制器

**Files:**
- Create: `Modules/QRTransfer/Sources/ContinuousScanner.swift`

**Interfaces:**
- Produces: `struct ContinuousScannerView: UIViewControllerRepresentable { init(onFrame: @escaping (String) -> Void) }`（回调固定主线程；同值 800ms 内去重）

- [ ] **Step 1: 写 ContinuousScanner.swift**

```swift
import SwiftUI
import AVFoundation

/// 连续扫码（区别于 App 内一次即停的 QRScannerView）：多帧二维码聚合接收用。
/// 同一内容 800ms 内只回调一次（对准静止的一帧不会刷屏，轮播自然交替放行）。
struct ContinuousScannerView: UIViewControllerRepresentable {
    var onFrame: (String) -> Void

    func makeUIViewController(context: Context) -> ContinuousScannerController {
        let vc = ContinuousScannerController()
        vc.onFrame = onFrame
        return vc
    }

    func updateUIViewController(_ uiViewController: ContinuousScannerController, context: Context) {}
}

final class ContinuousScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFrame: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var lastValue: String?
    private var lastTime = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue else { return }
        let now = Date()
        if value == lastValue, now.timeIntervalSince(lastTime) < 0.8 { return }
        lastValue = value
        lastTime = now
        onFrame?(value)
    }
}
```

- [ ] **Step 2: 编译验证**（命令同 Task 1 Step 7）

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Modules/QRTransfer PlanetPort.xcodeproj
git commit -m "feat(qrtransfer): 新增连续扫码控制器"
```

Body 说明：模块自有的 AVCapture 扫码封装，持续识别多帧二维码并按值+时间窗去重，为接收端聚合分片提供输入。

---

### Task 4: 分片阵列组件 + 分享/接收视图 + 模块文案

**Files:**
- Create: `Modules/QRTransfer/Sources/Views/ShardGridView.swift`
- Create: `Modules/QRTransfer/Sources/Views/QRShareView.swift`
- Create: `Modules/QRTransfer/Sources/Views/QRReceiveView.swift`
- Modify: `Modules/QRTransfer/Resources/QRTransfer.xcstrings`（填入全部 key）

**Interfaces:**
- Consumes: Task 2 的 `QRTransfer.encode/parse/decode/recommendedMaxModules`、`QRRender.generate`；Task 3 的 `ContinuousScannerView`
- Produces（App 侧 Task 5 使用的入口）:
  - `struct QRShareView: View { init(title: String, data: Data) }` —— 单帧自动退化静态码；多帧含速度四档(0.3/0.5/0.8/1.2s)与手动逐帧（方块可点跳转 + 前后按钮）
  - `struct QRReceiveView: View { init(onComplete: @escaping (Data) -> Void) }` —— 聚合分片、齐全+CRC 通过自动回调一次

- [ ] **Step 1: 写 ShardGridView.swift**

```swift
import SwiftUI

/// 分片方块阵列。两种形态：
/// 发送端：current 高亮当前帧，onTap 非空时可点跳转（手动模式）。
/// 接收端：received 填充已收格，未收格描边强调缺片。
struct ShardGridView: View {
    let total: Int
    var current: Int? = nil
    var received: Set<Int> = []
    var onTap: ((Int) -> Void)? = nil

    private let columns = [GridItem(.adaptive(minimum: 30), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            if total >= 1 {
                ForEach(1...total, id: \.self) { i in block(i) }
            }
        }
    }

    @ViewBuilder
    private func block(_ i: Int) -> some View {
        let isCurrent = current == i
        let isReceived = received.contains(i)
        // current==nil 即接收端形态：未收格描边
        let isMissing = current == nil && !isReceived
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isCurrent ? AnyShapeStyle(.tint)
                  : isReceived ? AnyShapeStyle(Color.tintColor.opacity(0.35))
                  : AnyShapeStyle(Color(uiColor: .quaternarySystemFill)))
            .overlay {
                if isMissing {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(uiColor: .tertiaryLabel), lineWidth: 1)
                }
            }
            .frame(height: 22)
            .onTapGesture { onTap?(i) }
    }
}
```

- [ ] **Step 2: 写 QRShareView.swift**

```swift
import SwiftUI

/// 分享端：展示分片二维码序列。单帧退化为静态码（无控件）；
/// 多帧提供速度四档与手动模式（方块点选跳帧 + 前后按钮）。
struct QRShareView: View {
    let title: String
    let data: Data

    @Environment(\.dismiss) private var dismiss
    @State private var frames: [String] = []
    @State private var tooLarge = false
    @State private var index = 0
    @State private var speed: Double = 0.5
    @State private var manual = false

    private let speeds: [Double] = [0.3, 0.5, 0.8, 1.2]
    private var side: CGFloat { UIScreen.main.bounds.width * 0.72 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if frames.isEmpty {
                    if tooLarge {
                        ContentUnavailableView {
                            Label(ql("qrtransfer.tooLarge"), systemImage: "exclamationmark.triangle")
                        } description: { Text(ql("qrtransfer.tooLarge.hint")) }
                    } else {
                        ProgressView()
                    }
                } else {
                    if let render = QRRender.generate(frames[index]) {
                        Image(uiImage: render.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: side, height: side)
                            .animation(.easeInOut(duration: 0.15), value: index)
                    }
                    Text(String(format: ql("qrtransfer.frame %d/%d"),
                                index + 1, frames.count))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if frames.count > 1 {
                        controls
                        ShardGridView(total: frames.count, current: index + 1,
                                      onTap: manual ? { jump($0) } : nil)
                            .padding(.horizontal, 20)
                    }
                    Spacer()
                }
            }
            .padding(.top, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ql("qrtransfer.done")) { dismiss() }
                }
            }
        }
        .task { encode() }
        .task(id: "\(manual)-\(speed)-\(frames.count)") { autoplay() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle(ql("qrtransfer.manual"), isOn: $manual)
                .font(.subheadline)
            if !manual {
                Picker(ql("qrtransfer.speed"), selection: $speed) {
                    ForEach(speeds, id: \.self) { s in
                        Text(String(format: "%.1fs", s)).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            } else {
                HStack(spacing: 28) {
                    Button {
                        jump(index)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    Button {
                        jump(index + 2)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
    }

    private func encode() {
        let maxModules = QRTransfer.recommendedMaxModules(side: side)
        do {
            frames = try QRTransfer.encode(data, maxModules: maxModules)
            index = 0
        } catch {
            tooLarge = true
        }
    }

    private func autoplay() {
        guard !manual, frames.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(speed * 1_000_000_000))
            index = (index + 1) % frames.count
        }
    }

    /// 1 基分片号跳转
    private func jump(_ oneBased: Int) {
        guard frames.count > 0 else { return }
        index = (oneBased - 1 + frames.count) % frames.count
    }
}
```

- [ ] **Step 3: 写 QRReceiveView.swift**

```swift
import SwiftUI

/// 接收端：连续扫码聚合分片。不区分单帧/多帧——解码任意帧 → 按 index 聚合
/// → 齐全后整体校验（Base45 → 解压 → CRC）→ 通过即回调一次。
/// total/checksum 与已收集合不一致（扫到新会话）时自动清空重来；CRC 失败同样清空。
struct QRReceiveView: View {
    let onComplete: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var total: Int?
    @State private var checksum: UInt32?
    @State private var chunks: [Int: String] = [:]
    @State private var corrupt = false
    @State private var finished = false

    var body: some View {
        NavigationStack {
            ZStack {
                ContinuousScannerView(onFrame: handle)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if let total {
                            ShardGridView(total: total, received: Set(chunks.keys))
                                .padding(.horizontal, 20)
                            Text(String(format: ql("qrtransfer.received %d/%d"),
                                        chunks.count, total))
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(corrupt ? ql("qrtransfer.corrupt") : ql("qrtransfer.waiting"))
                            .font(.footnote)
                            .foregroundStyle(corrupt ? Color.red : Color.secondary)
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle(Text(ql("qrtransfer.receiveTitle")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ql("qrtransfer.cancel")) { dismiss() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard !finished, let frame = QRTransfer.parse(text) else { return }
        // 换了传输会话（total 或 CRC 不同）：丢弃旧集合
        if let t = total, t != frame.total || checksum != frame.checksum {
            chunks = [:]
        }
        total = frame.total
        checksum = frame.checksum
        chunks[frame.index] = frame.payload
        corrupt = false
        guard chunks.count == frame.total else { return }
        let all = (1...frame.total).compactMap { i -> QRFrame? in
            chunks[i].map { QRFrame(total: frame.total, index: i,
                                    checksum: frame.checksum,
                                    length: frame.length, payload: $0) }
        }
        do {
            let data = try QRTransfer.decode(all)
            finished = true
            onComplete(data)
        } catch {
            chunks = [:]
            corrupt = true
        }
    }
}
```

- [ ] **Step 4: 填 QRTransfer.xcstrings**

`Modules/QRTransfer/Resources/QRTransfer.xcstrings` 完整替换为：

```json
{
  "sourceLanguage" : "zh-Hans",
  "strings" : {
    "qrtransfer.cancel" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Cancel" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "取消" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "取消" } }
      }
    },
    "qrtransfer.corrupt" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Checksum failed, please rescan" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "数据校验失败，请重新扫描" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "資料校驗失敗，請重新掃描" } }
      }
    },
    "qrtransfer.done" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Done" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "完成" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "完成" } }
      }
    },
    "qrtransfer.frame %d/%d" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Shard %d of %d" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "分片 %d/%d" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "分片 %d/%d" } }
      }
    },
    "qrtransfer.manual" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Manual" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "手动模式" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "手動模式" } }
      }
    },
    "qrtransfer.receiveTitle" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "QR Receive" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "二维码接收" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "二維碼接收" } }
      }
    },
    "qrtransfer.received %d/%d" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Received %d of %d" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已接收 %d/%d" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "已接收 %d/%d" } }
      }
    },
    "qrtransfer.speed" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Speed" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "切换速度" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "切換速度" } }
      }
    },
    "qrtransfer.tooLarge" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Data too large" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "数据过大" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "資料過大" } }
      }
    },
    "qrtransfer.tooLarge.hint" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Exceeds the QR transfer limit. Share via file or URL instead." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "超出二维码传输上限，请改用文件或 URL 分享" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "超出二維碼傳輸上限，請改用檔案或 URL 分享" } }
      }
    },
    "qrtransfer.waiting" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Point at the QR code" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "对准二维码，自动识别分片" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "對準二維碼，自動識別分片" } }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 5: 编译验证**（命令同 Task 1 Step 7）

Expected: `** BUILD SUCCEEDED **`。若 `Color.tintColor` 不可用（iOS 15 OK），用 `.tint` 的 `Color(UIColor.systemFill)` 兜底同义替换。

- [ ] **Step 6: Commit**

```bash
git add Modules/QRTransfer PlanetPort.xcodeproj
git commit -m "feat(qrtransfer): 新增分享与接收视图及分片阵列组件"
```

Body 说明：分享端支持速度四档与手动逐帧（方块点选跳转），单帧自动退化为静态码；接收端连续聚合分片、齐全校验后自动完成；配套模块三语文案。

---

### Task 5: App 侧接入（导入按钮 + 分享入口 + App 文案）

**Files:**
- Modify: `PlanetPort/Views/AddPlanetForm.swift:14-21`（新增 @State）、`96-109` 之间（第二位插入按钮）、`49-56` 之后（新增 sheet）
- Modify: `PlanetPort/Views/PlanetSettingsView.swift:142-146`（infoSection 内加分享行）、新增 @State 与 sheet
- Modify: `PlanetPort/../Shared/Localization/Localizable.xcstrings`（2 个新 key）

**Interfaces:**
- Consumes: Task 4 的 `QRReceiveView(onComplete:)`、`QRShareView(title:data:)`

- [ ] **Step 1: AddPlanetForm 增加"或动态二维码导入"按钮（第二位）**

`PlanetPort/Views/AddPlanetForm.swift` @State 区（第 17 行 `showScanner` 附近）新增：

```swift
    @State private var showPlanetReceiver = false
```

在"选择行星文件"按钮（第 94 行 `.buttonStyle(.plain)` 结束）之后、"扫码导入"按钮（第 96 行注释起）之前插入：

```swift
            // 动态二维码导入（模块 QRTransfer）：连续扫分片，收齐即回填 pendingData，
            // 复用与文件/URL 相同的"命名 + 添加 + 查重"后续流程。
            Button {
                showPlanetReceiver = true
            } label: {
                Label("addplanet.scanPlanetQr", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(downloading)
```

在现有 `.sheet(isPresented: $showScanner)`（第 49-56 行）之后追加：

```swift
        .sheet(isPresented: $showPlanetReceiver) {
            QRReceiveView { data in
                showPlanetReceiver = false
                do {
                    try validate(data)
                    pendingData = data
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
```

- [ ] **Step 2: PlanetSettingsView 增加二维码分享入口（仅自定义行星）**

`PlanetPort/Views/PlanetSettingsView.swift` @State 区（第 13 行附近）新增：

```swift
    @State private var showQRShare = false
    @State private var qrShareData: Data?
```

infoSection 中 `if let info = PlanetImporter.inspectPlanetFile(planet) { fileSizeRow(info) ... }`（第 142-145 行）之后、Section footer 之前插入：

```swift
                if !isOfficial, let url = planetFileURL {
                    Button {
                        qrShareData = try? Data(contentsOf: url)
                        showQRShare = qrShareData != nil
                    } label: {
                        HStack {
                            Text("planet.share.qr")
                            Spacer()
                            Image(systemName: "qrcode")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        }
                    }
                    .buttonStyle(.plain)
                }
```

在现有 `.sheet(isPresented: $showIconPicker)`（第 55 行）之后追加：

```swift
        .sheet(isPresented: $showQRShare) {
            if let qrShareData {
                QRShareView(title: planet?.displayName ?? loc("planet.title"), data: qrShareData)
            }
        }
```

- [ ] **Step 3: App Localizable.xcstrings 增加 2 个 key**

在 `Shared/Localization/Localizable.xcstrings` 的 `strings` 对象内（与 `addplanet.scanUrl` 同级）加入：

```json
    "addplanet.scanPlanetQr" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Or import via animated QR code" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "或动态二维码导入" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "或動態二維碼導入" } }
      }
    },
    "planet.share.qr" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Share via QR Code" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "二维码分享" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "二維碼分享" } }
      }
    },
```

注意保持 JSON 合法（逗号位置随插入点调整），写完后用 `python3 -m json.tool` 校验。

- [ ] **Step 4: 编译验证**（命令同 Task 1 Step 7）

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 真机/模拟器手测清单（构建以外的人工验证，交付时向用户说明已验项）**

1. 自定义行星 → 行星设置 → "二维码分享"：单帧 planet 显示静态码、无控件
2. 构造多帧（大 planet 或把 maxModules 调小重编）：分片计数、速度四档切换、手动模式方块点跳/左右按钮
3. 新增行星页 → "或动态二维码导入"：对准分享码，观察分片逐格点亮、齐全后自动关闭并回填"文件已就绪"
4. 添加时走既有 World ID 查重弹窗
5. 官方行星设置页无"二维码分享"行

- [ ] **Step 6: Commit**

```bash
git add PlanetPort/Views/AddPlanetForm.swift PlanetPort/Views/PlanetSettingsView.swift Shared/Localization/Localizable.xcstrings PlanetPort.xcodeproj
git commit -m "feat(planet): 接入动态二维码分享与导入"
```

Body 说明：新增行星表单第二位增加动态二维码导入入口，接收数据复用既有 pendingData 流程与查重；行星设置页为自定义行星提供二维码分享入口，官方行星不展示。

---

## Self-Review 结论

- 规格覆盖：仅自定义 planet 分享 ✓、单帧退化 ✓、接收端统一流水线自动结束 ✓、调速四档 ✓、手动逐帧（点方块+按钮）✓、分片阵列双端 ✓、均匀分片+末帧补 0 对齐（len 字段剥补位）✓、屏幕自适应+模块数/帧数硬顶 ✓、新增界面第二位按钮 ✓、模块化 pod-ready ✓、测试用例（用户明确要求）✓。
- 无占位符；接口签名在任务间一致（QRTransfer/QRFrame(length)/QRRender/ContinuousScannerView/QRShareView/QRReceiveView）。
- 已知风险：CIQRCodeGenerator 对过长输入返回 nil（容量探测与 encode 都依赖此行为，属预期路径）；Base45 已知向量以 RFC 9285 算法推导（"AB"→"BB8"、"He"→"%69"），若实现时实测不符以 RFC 算法为准修正测试注释；测试依赖模拟器可用（iPhone 16 Pro 已确认存在）。
