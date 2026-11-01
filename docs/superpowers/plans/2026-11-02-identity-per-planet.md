# 节点身份模式（共享 / 每行星独立）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iOS 主仓新分支上实现可切换的节点身份模式——所有行星共享一个 ZeroTier 身份（现状默认），或每个行星独立身份；模式往返切换完整保留各行星身份绑定，并正确处理中途行星增删。

**Architecture:** 现状为单身份：`datastore/identity.*` 被全部行星共用（`ZTBridge.mm` 的 `ztHookedPath` 只重定向 PLANET/MOON/PEER/NETCONF，不重定向 IDENTITY）。本功能新增模式偏好 `identity_per_planet`：开启时 hook 把 IDENTITY 读写重定向到 `datastore/planet-state/<activePlanetId>/identity.*`（该目录随删除行星级联清理）；身份文件缺失时 ZeroTier 核心自动生成新身份（惰性生成，无需 App 造身份）。模式切换由 `AppState.switchIdentityMode` 编排"停隧道 → 复制身份文件 → 重启隧道"；核心只在启动时读/生成身份、退出不回写，先停隧道仅为避免新旧核心并发访问身份文件。

**Tech Stack:** Swift / SwiftUI / Objective-C++（ZTBridge）/ NetworkExtension / xcodegen / xcodebuild。

## Global Constraints

- 分支：`feat/identity-per-planet`，从 `dev` 拉出。全程不 push。
- 用户规矩：不写测试用例（验证 = xcodebuild 构建通过）；提交信息遵循 Conventional Commits，type/scope 英文、description 与 Body 中文，必须 Body，禁止 Co-authored-by。
- xcstrings 编辑必须用文本级插入（保持 4 空格缩进、`" : "` 分隔、key 按字节排序、en → zh-Hans → zh-Hant 顺序），**禁止**用 python json.dumps 重写整个文件。每次编辑后用 `python3 -c "import json;json.load(open('Shared/Localization/Localizable.xcstrings'))"` 校验。
- 新增 Swift 文件后必须重跑 `xcodegen generate`（工程是 xcodegen 传统 sources 模式，非 fileSystemSynchronized）。
- 目标平台 iOS 17.0（本仓主线），不引入新依赖。
- 隐藏 ≠ 删除：本计划无隐藏需求，不做任何删除既有功能的改动。

## 关键背景（实现者必读）

1. **现状单身份**：`ZTBridge/ZTBridge.mm` 的 `ztStateFilePath` 把 IDENTITY_PUBLIC/SECRET 指到 datastore 根（`ZTBridge.mm:87-90`），`ztHookedPath` 不处理 IDENTITY 类型 → 全行星共享。
2. **planet-state 目录已存在**：`Shared/AppGroup.swift:21-24` 定义 `planetStateDir(planetId)`；moon/peer/netconf 已按行星重定向至此（`ZTBridge.mm:126-141`）；`AppConfigStore.deletePlanet` 删除行星时会整目录删除该目录（`AppConfigStore.swift:86`）→ 每行星身份文件放这里天然获得"删行星即删身份"。
3. **身份生成是核心内建能力**：核心启动时 `stateGet(IDENTITY)` 返回 -1（文件不存在）就会生成新身份。所以"某行星第一次以独立模式连接"= 不播种文件，核心自动生成。
4. **切换必须重启核心且复制要先于新核心启动**：核心只在启动（`ZT_Node_new`）时读/生成身份，退出（`ZT_Node_delete`）不回写；身份复制全部由 App 侧 `apply()` 完成，唯一硬性顺序是它必须先于新核心启动执行（否则新核心按缺失/旧文件自行生成或读到错身份）。先停隧道仅为避免新旧核心并发访问身份文件。正确顺序：写模式偏好 → `stopAndWait` → 复制身份 → `prepareAndStart`（偏好先写，新核心启动即按新模式定位身份路径）。两方向都成立：
   - 单→多：seed 把共享身份复制进 `planet-state/<activeId>/`（已有独立身份则 no-op，幂等），核心随后按该文件启动，沿用原身份。
   - 多→单：adopt 把用户选的行星身份写进根，核心随后按根目录文件启动，最终正确。
5. **`lastNodeId` 缓存自愈**：`AppState.cacheNodeId` 按激活行星实时刷新，独立模式下各行星各自缓存，共享模式下统一值，无需迁移。

## 模式切换语义（对齐用户需求）

- **单→多**：当前激活行星（`activePlanetId`）播种现有共享身份的副本（正在用的网络不中断、地址不变）；其余行星首次连接时由核心生成全新身份（其网络需在控制器重新授权——独立身份 = 新节点地址，这是 ZeroTier 固有语义，确认弹窗说明）。
- **多→单**：用户从"已生成独立身份的行星"中选一个，其身份复制为全局共享身份；**其余行星的独立身份文件原地保留**。
- **单→多→单→多 往返保真**：独立身份文件从不删除（除删行星），再次切多时已有文件的行星原样恢复（"要和之前一样"）；身份与行星绑定关系不变。
- **中途删行星**：`deletePlanet` 已删 `planetStateDir`，其身份随之消失；若它曾是共享身份来源——多→单是复制语义，共享身份已在根目录，不受影响。
- **中途加行星**：无论哪种模式都不预生成；独立模式下首次激活时核心生成新身份；共享模式期间新增的行星在切回独立模式时同样首次激活生成。无需在导入路径加代码。

## File Structure

- Create: `Shared/IdentityStore.swift` — 模式偏好读写 + 每行星身份文件操作（播种/采纳/地址解析）
- Modify: `Shared/AppGroup.swift` — 新偏好 key
- Modify: `ZTBridge/ZTBridge.mm` — hook 增加 IDENTITY 重定向
- Modify: `PlanetPort/AppState.swift` — `identityPerPlanet` 发布 + `switchIdentityMode` 编排
- Modify: `PlanetPort/Views/PrefsView.swift` — 设置页"节点身份"section + `IdentityModeSheet`
- Modify: `Shared/Localization/Localizable.xcstrings` — 11 个新 key 三语
- Modify: `README.md` / `README.en.md` / `README.zh-Hant.md` — 功能说明各一条

---

### Task 1: 身份存储层与核心 hook 重定向

**Files:**
- Create: `Shared/IdentityStore.swift`
- Modify: `Shared/AppGroup.swift:41`（prefParallaxEnabled 之后加一行 key）
- Modify: `ZTBridge/ZTBridge.mm:105-143`（ztHookedPath 增加 IDENTITY 分支）

**Interfaces:**
- Produces: `IdentityStore.perPlanet: Bool`（get/set）、`IdentityStore.hasPlanetIdentity(_ planetId: String) -> Bool`、`IdentityStore.planetIdentityAddress(_ planetId: String) -> String?`、`IdentityStore.seedSharedIdentity(to planetId: String)`、`IdentityStore.adoptSharedIdentity(from planetId: String)`、`AppGroup.prefIdentityPerPlanet: String`（值 `"identity_per_planet"`）。Task 2 的 UI 与编排依赖这些签名。

- [ ] **Step 1: 建分支**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
git --no-pager status   # 确认工作区干净（docs/软著登记 等未跟踪文件无妨）
git checkout -b feat/identity-per-planet dev
```

预期：切换到新分支，基于 dev 最新提交。

- [ ] **Step 2: AppGroup.swift 加偏好 key**

在 `prefParallaxEnabled` 之后插入：

```swift
    /// 每行星独立节点身份（默认 false = 全行星共享 datastore/identity.*）。
    /// Objective-C++ ztHookedPath 直读同名字符串 "identity_per_planet"。
    static let prefIdentityPerPlanet = "identity_per_planet"
```

- [ ] **Step 3: 新建 Shared/IdentityStore.swift**

```swift
import Foundation

/// 节点身份模式的存取与身份文件操作（App 侧管理；Extension 侧经
/// ZTBridge ztHookedPath 按同一模式偏好重定向读写，见 AppGroup.prefIdentityPerPlanet）。
/// 共享身份：datastore/identity.*（全行星共用，默认）；
/// 每行星身份：planet-state/<id>/identity.*（核心首次在该行星以独立模式启动时
/// 自行生成；目录随删除行星级联清理，见 AppConfigStore.deletePlanet）。
enum IdentityStore {
    static let identityPublicName = "identity.public"
    static let identitySecretName = "identity.secret"

    /// 是否每行星独立身份（默认 false = 共享）。
    static var perPlanet: Bool {
        get { AppGroup.defaults.bool(forKey: AppGroup.prefIdentityPerPlanet) }
        set { AppGroup.defaults.set(newValue, forKey: AppGroup.prefIdentityPerPlanet) }
    }

    /// 每行星身份文件 URL（planet-state/<id>/identity.*）。
    static func planetIdentityURL(_ planetId: String, secret: Bool = false) -> URL {
        AppGroup.planetStateDir(planetId)
            .appendingPathComponent(secret ? identitySecretName : identityPublicName)
    }

    /// 该行星是否已生成独立身份（以私钥文件为准）。
    static func hasPlanetIdentity(_ planetId: String) -> Bool {
        FileManager.default.fileExists(atPath: planetIdentityURL(planetId, secret: true).path)
    }

    /// 解析 identity.public 的节点地址：内容为 "address:publicKey"，
    /// 冒号前 10 位 hex 即 ZeroTier 节点地址。
    static func planetIdentityAddress(_ planetId: String) -> String? {
        guard let text = try? String(contentsOf: planetIdentityURL(planetId), encoding: .utf8),
              let address = text.split(separator: ":").first, address.count == 10 else { return nil }
        return String(address)
    }

    /// 播种：把当前共享身份复制为指定行星的独立身份（已有独立身份或共享身份
    /// 缺失时不动作）。切独立模式时让当前激活行星沿用现有身份，网络不中断。
    static func seedSharedIdentity(to planetId: String) {
        guard !hasPlanetIdentity(planetId) else { return }
        copyIdentity(from: AppGroup.datastore, to: AppGroup.planetStateDir(planetId))
    }

    /// 采纳：把指定行星的独立身份复制为全局共享身份（覆盖原共享身份文件）。
    /// 其余行星的独立身份文件原地保留，切回独立模式时原样恢复。
    static func adoptSharedIdentity(from planetId: String) {
        copyIdentity(from: AppGroup.planetStateDir(planetId), to: AppGroup.datastore)
    }

    /// 成对复制身份文件（源缺失跳过；目标已存在先移除再复制——seed 场景由
    /// hasPlanetIdentity 挡，adopt 场景覆盖即语义）。私钥保持 0600。
    private static func copyIdentity(from source: URL, to destination: URL) {
        let fm = FileManager.default
        for name in [identityPublicName, identitySecretName] {
            let src = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            try? fm.copyItem(at: src, to: dst)
            if name == identitySecretName {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            }
        }
    }
}
```

- [ ] **Step 4: ZTBridge.mm 的 ztHookedPath 增加 IDENTITY 重定向**

在 `ztHookedPath` 函数体内、`if (type == ZT_STATE_OBJECT_PLANET)` 块结束之后、`// 网络配置、Moon 和 Peer 缓存属于当前 Planet` 注释块之前，插入：

```objc
    // 每行星独立身份模式：identity 跟随当前 Planet（planet-state/<id>/），
    // 与 moon/peer/netconf 同目录隔离；文件缺失时核心自动生成新身份。
    // 共享模式不重定向（datastore 根，全行星共用）。模式切换由 App 侧
    // 重启核心生效（身份常驻核心内存）。
    if ((type == ZT_STATE_OBJECT_IDENTITY_PUBLIC || type == ZT_STATE_OBJECT_IDENTITY_SECRET) &&
        d && [d boolForKey:@"identity_per_planet"]) {
        NSString* planetId = [d stringForKey:@"planet_active_id"] ?: @"official";
        NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
        if (planetId.length == 0 || [planetId rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            planetId = @"official";
        }
        NSString* home = [rawPath stringByDeletingLastPathComponent];
        return [[[home stringByAppendingPathComponent:@"planet-state"]
            stringByAppendingPathComponent:planetId]
            stringByAppendingPathComponent:[rawPath lastPathComponent]];
    }
```

注意：`d` 在函数开头已是 `[[NSUserDefaults alloc] initWithSuiteName:kAppGroupID]`，可能为 nil，所以判定含 `d &&`。identity 的 rawPath 是 `<datastore>/identity.public`，`stringByDeletingLastPathComponent` 得 datastore，`lastPathComponent` 得文件名——目标即 `datastore/planet-state/<id>/identity.public`。

- [ ] **Step 5: 重生成工程并构建验证**

```bash
xcodegen generate
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort -destination 'generic/platform=iOS' -configuration Debug DEVELOPMENT_TEAM=7U7D63XYNK build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`。（若 scheme 名不确定，先 `xcodebuild -list -project PlanetPort.xcodeproj`。）

- [ ] **Step 6: Commit**

```bash
git add Shared/IdentityStore.swift Shared/AppGroup.swift ZTBridge/ZTBridge.mm
git commit -m "feat(identity): 每行星独立身份的存储层与核心重定向

现状全行星共用 datastore/identity.*，无身份隔离。新增模式偏好
identity_per_planet：开启时 ztHookedPath 将 IDENTITY 读写重定向到
planet-state/<活跃行星>/identity.*（目录随删行星级联清理，文件缺失时
核心自动生成新身份）；IdentityStore 提供播种（当前行星沿用共享身份，
网络不中断）与采纳（行星身份复制为共享身份）两种复制语义，为设置页
模式切换打底。"
```

---

### Task 2: 模式切换编排与设置页 UI

**Files:**
- Modify: `PlanetPort/AppState.swift`（`backgroundImage` 声明附近加 @Published；`clearBackgroundImage` 之后加切换函数）
- Modify: `PlanetPort/Views/PrefsView.swift`（网络 section 之后插入身份 section；文件末尾追加两个私有 View）
- Modify: `Shared/Localization/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 1 的 `IdentityStore` 全部 API、`AppGroup.prefIdentityPerPlanet`。
- Consumes: 已有 `VPNManager.connectionStatus` / `stopAndWait(timeout:completion:)` / `prepareAndStart`（`PlanetPort/VPNManager.swift:115-136,20-39,214-218`）。
- Produces: `AppState.identityPerPlanet: Bool`（@Published）、`AppState.switchIdentityMode(to:adopting:)`。

- [ ] **Step 1: AppState 加发布属性与切换编排**

在 `@Published var backgroundImage` 声明行后插入：

```swift
    /// 节点身份模式（true = 每行星独立身份）。设置页切换，切换会重启隧道核心。
    @Published var identityPerPlanet: Bool = IdentityStore.perPlanet
```

在 `clearBackgroundImage()` 函数后插入：

```swift
    /// 切换节点身份模式（设置页身份模式页触发）。
    /// 独立模式：当前激活行星播种现有共享身份（沿用，正在用的网络不中断），
    /// 其余行星首次连接时由核心生成新身份；共享模式：adopting 行星的独立身份
    /// 复制为全局共享身份，其余行星独立身份文件原地保留（切回独立模式时
    /// 原样恢复）。核心只在启动（ZT_Node_new）时读/生成身份、退出不回写，
    /// 身份复制全部由 App 侧 apply() 完成，唯一硬性顺序是它必须先于新核心
    /// 启动执行；先停隧道只为避免新旧核心并发访问身份文件。
    func switchIdentityMode(to perPlanet: Bool, adopting planetId: String?) {
        VPNManager.shared.connectionStatus { status in
            let running = status == .connected || status == .connecting || status == .reasserting
            Task { @MainActor in
                IdentityStore.perPlanet = perPlanet
                identityPerPlanet = perPlanet
                let apply = {
                    if perPlanet {
                        IdentityStore.seedSharedIdentity(to: activePlanetId)
                    } else if let planetId {
                        IdentityStore.adoptSharedIdentity(from: planetId)
                    }
                }
                guard running else {
                    apply()
                    return
                }
                VPNManager.shared.stopAndWait { _ in
                    Task { @MainActor in
                        apply()
                        VPNManager.shared.prepareAndStart { _, _ in }
                    }
                }
            }
        }
    }
```

- [ ] **Step 2: PrefsView 加身份模式 section**

在 PrefsView 中 `Section { Toggle("prefs.ondemand"...) }` 整个 section 结束之后、语言 Section 之前，插入：

```swift
            Section {
                Button {
                    showIdentityMode = true
                } label: {
                    HStack {
                        Text("prefs.identity.mode")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(app.identityPerPlanet ? "prefs.identity.mode.perPlanet"
                                                    : "prefs.identity.mode.shared")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("prefs.identity.sectionHeader")
            } footer: {
                Text("prefs.identity.footer")
            }
```

同时在 PrefsView 的 @State 区（`showThemePicker` 声明附近）加：

```swift
    @State private var showIdentityMode = false
```

并在 `.sheet(isPresented: $showThemePicker) { ThemeColorPickerSheet() }` 之后追加：

```swift
        .sheet(isPresented: $showIdentityMode) {
            IdentityModeSheet()
        }
```

- [ ] **Step 3: PrefsView.swift 文件末尾追加两个私有 View**

```swift
/// 身份模式选择页：共享 / 每行星独立 两行，点当前模式无动作；切独立先
/// alert 确认（其余行星将生成新身份、网络需重新授权），切共享进入身份
/// 选择页（无候选行星时直接切换，保持现共享身份）。
private struct IdentityModeSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPerPlanet = false

    /// 已生成独立身份的行星（切共享时的候选；地址取自 identity.public）。
    private var candidates: [PlanetProfile] {
        app.planets.filter { IdentityStore.hasPlanetIdentity($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    modeRow(titleKey: "prefs.identity.mode.shared", isCurrent: !app.identityPerPlanet) {
                        if candidates.isEmpty {
                            app.switchIdentityMode(to: false, adopting: nil)
                            dismiss()
                        } else {
                            showPick = true
                        }
                    }
                    modeRow(titleKey: "prefs.identity.mode.perPlanet", isCurrent: app.identityPerPlanet) {
                        confirmPerPlanet = true
                    }
                } footer: {
                    Text("prefs.identity.footer")
                }
            }
            .navigationTitle("prefs.identity.sectionHeader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .alert("prefs.identity.perPlanet.confirmTitle", isPresented: $confirmPerPlanet) {
                Button("prefs.identity.perPlanet.confirmAction") {
                    app.switchIdentityMode(to: true, adopting: nil)
                    dismiss()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("prefs.identity.perPlanet.confirmMessage")
            }
            .navigationDestination(isPresented: $showPick) {
                IdentityPickView(candidates: candidates) { planetId in
                    app.switchIdentityMode(to: false, adopting: planetId)
                    dismiss()
                }
            }
        }
    }

    @State private var showPick = false

    /// 模式行：当前模式纯展示（checkmark），其它模式可点触发 action。
    private func modeRow(titleKey: LocalizedStringKey, isCurrent: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { action() } }
        .foregroundStyle(.primary)
    }
}

/// 共享身份选择页：列出已生成独立身份的行星，点选其身份成为全局共享身份。
private struct IdentityPickView: View {
    let candidates: [PlanetProfile]
    let onPick: (String) -> Void

    var body: some View {
        Form {
            Section {
                if candidates.isEmpty {
                    Text("prefs.identity.pick.empty")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { planet in
                    Button {
                        onPick(planet.id)
                    } label: {
                        HStack {
                            Image(PlanetIcon.assetName(for: planet))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .frame(width: 24, height: 24)
                                .background(PlanetIcon.tint(for: planet),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(planet.displayName)
                            Spacer()
                            Text(IdentityStore.planetIdentityAddress(planet.id) ?? "—")
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("prefs.identity.pick.footer")
            }
        }
        .navigationTitle("prefs.identity.pick.title")
        .navigationBarTitleDisplayMode(.inline)
    }
}
```

实现者注：`@State private var showPick` 按上述片段放在 `IdentityModeSheet` 内（与 confirmPerPlanet 并列即可，不必恰好是示例中的位置）；`PlanetProfile` 需 `Identifiable`（已满足，现有代码 `ForEach(candidates)` 直接可用）。若编译器提示 `showPick` 未声明，把它移到其它 @State 旁即可——声明顺序不影响行为。

- [ ] **Step 4: xcstrings 加 11 个 key（文本级编辑）**

key 按字节排序插入。先用 `grep -n '"prefs\.' Shared/Localization/Localizable.xcstrings | head -40` 找到所有 prefs.* key，插入位置 = 字节序小于 `prefs.identity.footer` 的最后一个 key 块结束（`},`）之后。11 个 key 按字节序整体插入（identity 内部顺序：footer < mode < mode.perPlanet < mode.shared < perPlanet.confirmAction < perPlanet.confirmMessage < perPlanet.confirmTitle < pick.empty < pick.footer < pick.title < sectionHeader；注意 `.`(0x2E) 排序在字母前，`mode.shared` < `perPlanet` 成立）。

插入块（缩进 4 空格、`" : "` 分隔、每 key 内 en → zh-Hans → zh-Hant）：

```
    "prefs.identity.footer" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "All planets share one node identity, or each planet uses its own. Separate identities cannot be correlated across planets, keeping networks isolated."
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "所有行星共用一个节点身份，或每个行星使用独立身份。独立身份的行星之间互不可关联，适合隔离不同网络的隐私。"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "所有行星共用一個節點身份，或每個行星使用獨立身份。獨立身份的行星之間互不可關聯，適合隔離不同網路的隱私。"
          }
        }
      }
    },
    "prefs.identity.mode" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Identity Mode"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "身份模式"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "身份模式"
          }
        }
      }
    },
    "prefs.identity.mode.perPlanet" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Per-Planet"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "每行星独立"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "每行星獨立"
          }
        }
      }
    },
    "prefs.identity.mode.shared" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Shared Identity"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "共享身份"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "共享身份"
          }
        }
      }
    },
    "prefs.identity.perPlanet.confirmAction" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Switch"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "切换"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "切換"
          }
        }
      }
    },
    "prefs.identity.perPlanet.confirmMessage" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The current planet keeps its identity; other planets get a new one on first connect, and their networks must be authorized again."
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "当前行星沿用现有身份；其余行星首次连接时生成新身份，其已加入的网络需要重新授权。"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "當前行星沿用現有身份；其餘行星首次連接時生成新身份，其已加入的網路需要重新授權。"
          }
        }
      }
    },
    "prefs.identity.perPlanet.confirmTitle" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Switch to per-planet identities?"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "切换为每行星独立身份？"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "切換為每行星獨立身份？"
          }
        }
      }
    },
    "prefs.identity.pick.empty" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "No planet has its own identity yet"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "尚无行星生成独立身份"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "尚無行星生成獨立身份"
          }
        }
      }
    },
    "prefs.identity.pick.footer" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "The chosen identity becomes the node identity for all planets. Each planet's own identity is kept and restored when you switch back."
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "选定的身份将成为所有行星共用的节点身份。各行星现有独立身份保留，切回独立模式时恢复。"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "選定的身份將成為所有行星共用的節點身份。各行星現有獨立身份保留，切回獨立模式時恢復。"
          }
        }
      }
    },
    "prefs.identity.pick.title" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Choose Shared Identity"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "选择共享身份"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "選擇共享身份"
          }
        }
      }
    },
    "prefs.identity.sectionHeader" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Node Identity"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "节点身份"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "節點身份"
          }
        }
      }
    },
```

编辑后校验：

```bash
python3 -c "import json;json.load(open('Shared/Localization/Localizable.xcstrings'));print('OK')"
git --no-pager diff --stat Shared/Localization/Localizable.xcstrings   # 应只有 200 行左右新增，无既有行改动
```

- [ ] **Step 5: 构建验证**

```bash
xcodegen generate
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort -destination 'generic/platform=iOS' -configuration Debug DEVELOPMENT_TEAM=7U7D63XYNK build 2>&1 | tail -5
```

预期：`BUILD SUCCEEDED`。

- [ ] **Step 6: Commit**

```bash
git add PlanetPort/AppState.swift PlanetPort/Views/PrefsView.swift Shared/Localization/Localizable.xcstrings
git commit -m "feat(identity): 设置页身份模式切换与共享身份选择

设置页新增「节点身份」区：模式页二选一（共享/每行星独立），切独立
alert 确认（当前行星沿用现有身份，其余行星首次连接生成新身份、网络
需重新授权）；切共享进入身份选择页（列出已生成独立身份的行星与节点
地址，点选采纳为全局共享身份，其余行星身份保留、切回时恢复）。
切换编排走 AppState.switchIdentityMode：先写模式偏好再停隧道，复制
身份文件放在停隧道之后（避免新旧核心并发访问身份文件），
在跑则随后重启隧道，未跑仅落盘下次启动生效。"
```

---

### Task 3: README 三语与收尾自查

**Files:**
- Modify: `README.md` / `README.en.md` / `README.zh-Hant.md`（"行星（Planet）管理"功能节各加一条）

**Interfaces:**
- Consumes: 无代码依赖，纯文档 + 最终验证。

- [ ] **Step 1: README.md 加功能条目**

`README.md` 的 `### 行星（Planet）管理` 小节 bullet 列表末尾加：

```markdown
- **节点身份模式**：所有行星共用一个节点身份，或每个行星使用独立身份（互不可关联）；可随时切换，各行星身份保留、切回即恢复
```

- [ ] **Step 2: README.en.md 加对应条目**

`### Planet Management` 小节 bullet 列表末尾加：

```markdown
- **Node identity mode**: share one node identity across all planets, or give each planet its own (uncorrelated); switch anytime — each planet's identity is kept and restored when you switch back
```

- [ ] **Step 3: README.zh-Hant.md 加对应条目**

对应"行星管理"小节 bullet 列表末尾加：

```markdown
- **節點身份模式**：所有行星共用一個節點身份，或每個行星使用獨立身份（互不可關聯）；可隨時切換，各行星身份保留、切回即恢復
```

- [ ] **Step 4: 最终构建验证 + 全量 diff 自查**

```bash
xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort -destination 'generic/platform=iOS' -configuration Debug DEVELOPMENT_TEAM=7U7D63XYNK build 2>&1 | tail -5
git --no-pager diff dev..feat/identity-per-planet --stat
git --no-pager log dev..feat/identity-per-planet --oneline
```

预期：BUILD SUCCEEDED；diff 仅覆盖计划列出的 8 个文件；3 个提交。

自查清单（逐条人工核对 diff）：
1. hook 新分支的 planetId 清洗与既有 MOON/PEER 分支一致（invalid 字符回退 official）。
2. `switchIdentityMode` 中 `IdentityStore.perPlanet = perPlanet` 先于 stopAndWait（新核心启动前模式偏好已就位，身份路径定位正确）。
3. xcstrings 无既有行被改动（diff 只有新增块）。
4. 未引入任何 17+ 之外的新 API 依赖（`navigationDestination(isPresented:)` 为 iOS 16+，主线 target 17.0 无碍）。
5. 无调试代码、无 print、无 TODO 遗留。

- [ ] **Step 5: Commit**

```bash
git add README.md README.en.md README.zh-Hant.md
git commit -m "docs(readme): 补充节点身份模式功能说明

三语 README 的行星管理功能列表各加一条：共享/独立身份可切换、
各行星身份保留、切回即恢复。"
```

## Self-Review 记录

- 需求覆盖：可切换（Task 2 模式页）、多→单选身份（IdentityPickView）、单→多恢复如前（身份文件原地保留 + seed no-op）、身份与行星绑定不变（文件从不迁移）、中途增删（删=既有级联清理；增=惰性生成）——全覆盖。
- 无占位：所有步骤含完整代码与命令。
- 类型一致：`IdentityStore` API 在 Task 1 定义、Task 2 消费签名一致；`switchIdentityMode(to:adopting:)` 的调用点与定义一致。
