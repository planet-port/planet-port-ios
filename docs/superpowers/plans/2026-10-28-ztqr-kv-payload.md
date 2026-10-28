# ZTQR 载荷 KV 容器（ZTP）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 二维码分享载荷由裸 planet 字节升级为 ZTP KV 容器，携带 planet 二进制 + 名称/图标/颜色编号，接收端扫码后预填身份表单。

**Architecture:** 三层分工——QRTransfer 模块新增 `PayloadContainer`（纯 wire format 编解码，对 key 含义零假设）；App 层新增 `PlanetPayload`（key 1-4 约定 + `PlanetProfile` 字段映射）；发送端组容器替换原裸 planet 数据，接收端解析容器预填表单。帧协议 `ZTQR1|...` 与文件/URL 导入路径不动。

**Tech Stack:** Swift / SwiftUI。无新第三方依赖。

**Spec:** docs/superpowers/specs/2026-10-28-ztqr-kv-payload-design.md（已定稿，commit be18c24）

## Global Constraints

- **不写测试用例**（用户全局规则 7.1，本次未被要求覆盖）。每任务验证 = `xcodegen generate` + `xcodebuild` 编译通过。
- 模块代码（Modules/QRTransfer）**禁止 import 任何 App 代码**，只用系统框架（pod-ready 原则）。
- App 层新文案走 `Shared/Localization/Localizable.xcstrings`（三语 zh-Hans/zh-Hant/en）。
- wire format 细节以设计文档为准：magic `"ZTP"`（3 字节）、key 1 字节（0 非法）、len 4 字节小端、条目顺序无关、未知 key 由解析方跳过、重复 key 取后值、数据尾即容器尾。
- git 提交：中文 Conventional Commits，必须有 Body，禁止 Co-Authored-By。
- 新文件加入 target 后必须 `xcodegen generate` 再编译（project.yml 按目录 glob）。

---

### Task 1: 模块层 PayloadContainer（ZTP wire format 编解码）

**Files:**
- Create: `Modules/QRTransfer/Sources/PayloadContainer.swift`

**Interfaces:**
- Consumes: 无（纯 Foundation）
- Produces（Task 2 依赖）:
  - `enum PayloadContainer { static func encode(_ fields: [(key: UInt8, value: Data)]) -> Data; static func decode(_ data: Data) -> [UInt8: Data]? }`

- [ ] **Step 1: 写 PayloadContainer.swift**

```swift
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
```

- [ ] **Step 2: 重新生成工程并编译**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
xcodegen generate
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'generic/platform=iOS Simulator' -quiet build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Modules/QRTransfer/Sources/PayloadContainer.swift PlanetPort.xcodeproj
git commit -m "feat(qrtransfer): 新增 ZTP KV 容器编解码"
```

Body 说明：二维码载荷层引入无序 KV 容器（magic "ZTP"，条目 = key 1 字节 + len 4 字节小端 + value），未知 key 由解析方忽略、重复 key 取后值，wire format 一版定死，业务演进只发生在应用层 key 约定。

---

### Task 2: App 层 PlanetPayload（key 约定 + 字段映射）

**Files:**
- Create: `PlanetPort/PlanetPayload.swift`

**Interfaces:**
- Consumes: Task 1 的 `PayloadContainer.encode/decode`
- Produces（Task 3/4 依赖）:
  - `enum PlanetPayload`，常量 `keyPlanet=1, keyName=2, keyIcon=3, keyIconColor=4`
  - `struct PlanetPayload.SharePayload: Equatable { let planet: Data; let name: String?; let icon: String?; let iconColor: String? }`
  - `static func container(planet: Data, name: String, icon: String?, iconColor: String?) -> Data`
  - `static func parse(_ data: Data) -> SharePayload?`

- [ ] **Step 1: 写 PlanetPayload.swift**

```swift
import Foundation

/// ZTP 容器的 PlanetPort 应用层 key 约定（key 语义归应用层，组件零假设）：
/// 1=planet 二进制(必备) 2=名称 3=图标 key 4=图标底色 hex。
enum PlanetPayload {
    static let keyPlanet: UInt8 = 1
    static let keyName: UInt8 = 2
    static let keyIcon: UInt8 = 3
    static let keyIconColor: UInt8 = 4

    struct SharePayload: Equatable {
        let planet: Data
        let name: String?
        let icon: String?
        let iconColor: String?
    }

    /// 组容器：名称必带（空名防御性省略）；icon/iconColor 为 nil 时省略条目。
    static func container(planet: Data, name: String, icon: String?, iconColor: String?) -> Data {
        var fields: [(key: UInt8, value: Data)] = [(keyPlanet, planet)]
        if !name.isEmpty { fields.append((keyName, Data(name.utf8))) }
        if let icon { fields.append((keyIcon, Data(icon.utf8))) }
        if let iconColor { fields.append((keyIconColor, Data(iconColor.utf8))) }
        return PayloadContainer.encode(fields)
    }

    /// 解析容器。容器非法（magic/边界不成立）或 planet 字段缺失 → nil。
    /// 文本字段按 UTF-8 解码，失败按缺省处理（保留 planet 可用性）。
    static func parse(_ data: Data) -> SharePayload? {
        guard let fields = PayloadContainer.decode(data),
              let planet = fields[keyPlanet] else { return nil }
        func text(_ key: UInt8) -> String? {
            fields[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        return SharePayload(planet: planet, name: text(keyName),
                            icon: text(keyIcon), iconColor: text(keyIconColor))
    }
}
```

- [ ] **Step 2: 重新生成工程并编译**（命令同 Task 1 Step 2）

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add PlanetPort/PlanetPayload.swift PlanetPort.xcodeproj
git commit -m "feat(planet): ZTP 容器应用层字段约定与编解码映射"
```

Body 说明：定义 PlanetPort 对 ZTP 容器的 key 约定（planet/名称/图标/底色），提供 PlanetProfile 元数据与容器字段的相互映射；planet 为必备字段，其余可选。

---

### Task 3: 发送端组容器

**Files:**
- Modify: `PlanetPort/Views/PlanetSettingsView.swift`（`shareQR()` 函数，当前在文件 ~258 行）

**Interfaces:**
- Consumes: Task 2 的 `PlanetPayload.container(planet:name:icon:iconColor:)`

- [ ] **Step 1: 修改 shareQR()**

将：

```swift
    /// 读取 planet 文件进入二维码分享；读取失败(并发删除)不弹页。
    /// 会话在此创建即开始编码渲染，与 sheet 呈现动画并行，
    /// 避免 sheet 内容 .task 等动画播完才触发导致首帧迟滞。
    private func shareQR() {
        guard let url = planetFileURL, let data = try? Data(contentsOf: url) else { return }
        qrShareSession = QRShareSession(
            data: data, side: UIScreen.main.bounds.width * 0.72)
    }
```

改为：

```swift
    /// 读取 planet 文件并连同名称/图标/底色组成 ZTP 容器进入二维码分享；
    /// 读取失败(并发删除)不弹页。会话在此创建即开始编码渲染，与 sheet
    /// 呈现动画并行，避免 sheet 内容 .task 等动画播完才触发导致首帧迟滞。
    private func shareQR() {
        guard let url = planetFileURL, let data = try? Data(contentsOf: url) else { return }
        let container = PlanetPayload.container(planet: data, name: planet.name,
                                                icon: planet.icon, iconColor: planet.iconColor)
        qrShareSession = QRShareSession(
            data: container, side: UIScreen.main.bounds.width * 0.72)
    }
```

说明：分享入口仅 `!isOfficial` 时出现，`planet.name` 直接用存储名；`planet.icon`/`planet.iconColor` 未设置为 nil 时容器自动省略条目。

- [ ] **Step 2: 编译**（无需 xcodegen，无新文件）

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'generic/platform=iOS Simulator' -quiet build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add PlanetPort/Views/PlanetSettingsView.swift
git commit -m "feat(planet): 二维码分享携带名称图标底色元数据"
```

Body 说明：分享载荷由裸 planet 文件升级为 ZTP KV 容器，planet 二进制外附带当前配置的名称、图标 key 与底色 hex；未设置的可选字段不出现在容器中。

---

### Task 4: 接收端解析容器并预填表单

**Files:**
- Modify: `PlanetPort/Views/AddPlanetForm.swift`（`animal`/`colorHex` 声明 ~10-11 行、`showPlanetReceiver` sheet ~64-74 行）
- Modify: `PlanetPort/Views/AddPlanetPage.swift`（`AddPlanetForm(...)` 调用 ~28 行）
- Modify: `Shared/Localization/Localizable.xcstrings`（新增 1 个 key）

**Interfaces:**
- Consumes: Task 2 的 `PlanetPayload.parse(_:) -> SharePayload?`

- [ ] **Step 1: AddPlanetForm 的 animal/colorHex 改为 Binding**

将（第 10-11 行）：

```swift
    let animal: String
    let colorHex: String
```

改为：

```swift
    @Binding var animal: String
    @Binding var colorHex: String
```

（注释同步改为「与首页 Pager 的预览卡片共享」语义不变，只是改为可写。）

- [ ] **Step 2: AddPlanetPage 调用处传 Binding**

将（第 28-29 行）：

```swift
                AddPlanetForm(name: $previewName, animal: animal, colorHex: colorHex,
                              isCurrentPage: isCurrentPage) { profile in
```

改为：

```swift
                AddPlanetForm(name: $previewName, animal: $animal, colorHex: $colorHex,
                              isCurrentPage: isCurrentPage) { profile in
```

- [ ] **Step 3: 扫码回调解析容器并预填**

将（`.sheet(isPresented: $showPlanetReceiver)` 块）：

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

改为：

```swift
        .sheet(isPresented: $showPlanetReceiver) {
            QRReceiveView { data in
                showPlanetReceiver = false
                // 解析 ZTP 容器；非法容器（magic/边界不成立、缺 planet 字段）
                // 或旧版裸 planet 载荷都走统一"数据无效"提示。
                guard let payload = PlanetPayload.parse(data) else {
                    alert = loc("addplanet.qrInvalid")
                    return
                }
                do {
                    try validate(payload.planet)
                    pendingData = payload.planet
                    if let name = payload.name, !name.isEmpty { self.name = name }
                    if let icon = payload.icon { animal = icon }
                    if let iconColor = payload.iconColor { colorHex = iconColor }
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
```

行为说明（无需额外代码）：
- 预填名称写入 `name` Binding 后，`AddPlanetPage` 的 `previewName.onChange` 检测到与动物本地化名不同 → `nameEditedByUser = true` → 预填名不会被后续身份联动覆盖。
- 预填 icon key 若在接收端 Assets 中不存在（跨版本），`PlanetIcon` 已有按名称哈希回退，`Color(hex:) ?? .gray` 兜底底色，无需校验。
- 容器解析成功但 planet 首字节非 `0x01` → 走既有 `catch`（badHeader 提示）。

- [ ] **Step 4: Localizable.xcstrings 新增 addplanet.qrInvalid**

在 `strings` 对象内 `addplanet.previewName` 条目之前插入（保持 JSON 合法，写完 `python3 -m json.tool` 校验）：

```json
    "addplanet.qrInvalid" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Invalid QR code data" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "二维码数据无效" } },
        "zh-Hant" : { "stringUnit" : { "state" : "translated", "value" : "二維碼資料無效" } }
      }
    },
```

- [ ] **Step 5: 编译**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'generic/platform=iOS Simulator' -quiet build
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add PlanetPort/Views/AddPlanetForm.swift PlanetPort/Views/AddPlanetPage.swift Shared/Localization/Localizable.xcstrings
git commit -m "feat(planet): 扫码导入解析 ZTP 容器并预填身份表单"
```

Body 说明：接收端解析 ZTP 容器取 planet 二进制回填既有 pendingData 流程，并将分享方名称/图标/底色预填到新增表单与首页预览区（可改，走既有添加+查重）；非法容器与旧版裸 planet 载荷统一提示数据无效。

---

### Task 5: 回归验证（无代码变更，不产生提交）

- [ ] **Step 1: 跑既有测试确认无回归**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
xcodebuild test -project PlanetPort.xcodeproj -scheme PlanetPort \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -quiet
```

Expected: 既有 QRTransferCodecTests / QRTransferFrameTests 全绿（本次未新增用例；PayloadContainer 为新增类型，不触碰既有路径）。

- [ ] **Step 2: 双机/模拟器手测清单（交付时向用户说明已验项）**

1. 自定义行星（已设名称/图标/底色）→ 设置页「二维码分享」→ 另一台设备「或动态二维码导入」扫码 → 名称/图标/底色预填 + 「文件已就绪」→ 添加 → 行星带元数据入库、预览区显示分享方图标底色。
2. 未设图标/底色的行星分享 → 接收端仅预填名称。
3. 多帧大 planet：分片阵列逐格点亮、齐全自动完成（既有行为不变，载荷变大后仍受 tooLarge 上限保护）。
4. 旧版 app 分享的裸 planet 码 / 其他内容码 → 统一提示「二维码数据无效」。
5. 文件导入 / URL 导入路径行为不变（仍走裸 planet 文件校验）。

---

## Self-Review 结论

- 规格覆盖：wire format（Task 1）、应用层 key 约定与映射（Task 2）、发送端组容器（Task 3）、接收端预填 + 兜底提示（Task 4）、旧版裸 planet 不兼容提示（Task 4 Step 3/Step 4）、文件/URL 路径不动（Task 5 手测项 5）✓。
- 无占位符；接口在任务间一致（`PayloadContainer.encode([(key:value:)])`/`decode`、`PlanetPayload.container/parse/SharePayload`、Binding 名 `animal`/`colorHex`）。
- 已知风险：AddPlanetForm 的 animal/colorHex 由 let 改 @Binding 后，上游仅 AddPlanetPage 一处调用（已确认全仓唯一调用点）；planet 容器比裸 planet 多 ~30 字节，压缩后对帧数影响可忽略。
