# 动物图标体系与复制/分享交互改造 · 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 图标体系切换为 92 个白色动物矢量图标（自定义图形+底色），重构新增行星页身份区，并补齐全局的复制 / 二维码 / 系统分享交互。

**Architecture:** 资产管线（SVG→PDF 脚本，仓库外源图）→ 三语本地化注入 → 数据模型与 `PlanetIcon` 重构（icon 存动物 key、新增 iconColor hex）→ 公共 `CopyableValue` 组件 → 各视图逐个改造。每个任务结束工程可编译。

**Tech Stack:** SwiftUI (iOS 17)、XcodeGen（project.yml）、系统 `CIQRCodeGenerator` / `ShareLink`（零新依赖）、rsvg-convert（librsvg）。

**设计文档:** `docs/superpowers/specs/2026-10-24-animal-icons-copy-and-share-design.md`

## Global Constraints

- 部署目标 iOS 17.0；不引入任何第三方库。
- 本地化三语：zh-Hans / zh-Hant / en，源语言 zh-Hans；文案 key 风格与现有 `Localizable.xcstrings` 一致（小写模块前缀 + 驼峰）。
- 不新增自动化测试；每任务验证 = `xcodegen generate` + `xcodebuild` 编译通过，最终人工核对。
- 源图已移出仓库：`/Users/zivyuan/GoziLib/Zerotier/Resources/ios/design/animals/`（下文 `$ANIMALS`）。转换脚本也放那里（非源码）。
- 图标 key 规则：有效自定义 key 永久生效；未设置/旧值无效 → 按**名称** djb2 哈希确定性回退（名称不变则图标不变）。底色：自定义 hex 优先，否则按 **id** 哈希取 ThemeManager tint（老行星颜色不变）。官方行星同规则、无特判。
- 复制图标字号 ≈ 文字字高的 2/3（比例参照 NetworkCardView IP 复制图标：caption2 文字配 9pt、正文配 11pt）。
- git 命令一律加 `--no-pager`；提交信息 Conventional Commits 中文；禁止 Co-authored-by。
- "隐藏" ≠ 删除（本计划中被移除的 UI 均为「重写替代」，非隐藏需求）。
- 构建验证命令（下文各任务引用为 `BUILD_CMD`）：
  `cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios && xcodegen generate && xcodebuild -project PlanetPort.xcodeproj -scheme PlanetPort -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
  预期输出含 `BUILD SUCCEEDED`。

---

### Task 1: 动物图标资产管线（92 × SVG → 白色 PDF imageset）

**Files:**
- Create: `/Users/zivyuan/GoziLib/Zerotier/Resources/ios/design/animals/convert-to-pdf.sh`（仓库外，一次性工具）
- Create: `PlanetPort/Assets.xcassets/animal-<key>.imageset/` × 92（脚本生成）

**Interfaces:**
- Produces: 资产名 `animal-<key>`（如 `animal-cat`），供 `Image("animal-cat")` 使用；key 列表见 Task 3 的 `PlanetIcon.catalog`（同一批 92 个文件名去扩展名）。

- [ ] **Step 1: 安装工具链**

```bash
command -v rsvg-convert || brew install librsvg
```

预期：`command -v rsvg-convert` 输出路径（如 `/opt/homebrew/bin/rsvg-convert`）。

- [ ] **Step 2: 写转换脚本**

写入 `/Users/zivyuan/GoziLib/Zerotier/Resources/ios/design/animals/convert-to-pdf.sh`：

```bash
#!/bin/bash
# 动物 SVG → 白色 PDF imageset 批量转换(一次性工具)。
# 用法: ./convert-to-pdf.sh <svg目录> <Assets.xcassets路径>
# 产物: <Assets>/animal-<key>.imageset/{animal-<key>.pdf, Contents.json}
set -euo pipefail
SRC="${1:?用法: convert-to-pdf.sh <svg目录> <Assets.xcassets路径>}"
DST="${2:?缺 Assets.xcassets 路径}"
command -v rsvg-convert >/dev/null || { echo "需要 rsvg-convert (brew install librsvg)"; exit 1; }

count=0
for svg in "$SRC"/*.svg; do
  key=$(basename "$svg" .svg)
  [ "$key" = "index" ] && continue
  set="$DST/animal-$key.imageset"
  mkdir -p "$set"
  # 白色烧入 PDF: currentColor → #FFFFFF
  sed 's/fill="currentColor"/fill="#FFFFFF"/g' "$svg" > "$set/tmp.svg"
  rsvg-convert -f pdf -o "$set/animal-$key.pdf" "$set/tmp.svg"
  rm "$set/tmp.svg"
  cat > "$set/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "animal-$key.pdf",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
EOF
  count=$((count + 1))
done
echo "完成: $count 个 imageset"
```

```bash
chmod +x /Users/zivyuan/GoziLib/Zerotier/Resources/ios/design/animals/convert-to-pdf.sh
```

- [ ] **Step 3: 运行并验证产物**

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
ANIMALS=/Users/zivyuan/GoziLib/Zerotier/Resources/ios/design/animals
"$ANIMALS/convert-to-pdf.sh" "$ANIMALS" "$PWD/PlanetPort/Assets.xcassets"
ls -d PlanetPort/Assets.xcassets/animal-*.imageset | wc -l   # 预期 92
head -c 8 PlanetPort/Assets.xcassets/animal-cat.imageset/animal-cat.pdf; echo   # 预期 %PDF-
```

- [ ] **Step 4: 构建验证资产可编译**

运行 `BUILD_CMD`（见 Global Constraints）。预期 `BUILD SUCCEEDED`。

- [ ] **Step 5: Commit**

```bash
git --no-pager add PlanetPort/Assets.xcassets
git --no-pager commit -m "feat(assets): 动物图标矢量资产(92 个白色 PDF imageset)

SVG 原稿在仓库外 Resources/ios/design/animals,由 convert-to-pdf.sh
将 currentColor 替换为白色后经 rsvg-convert 转为矢量 PDF;
single scale + 保留矢量表示,资产名 animal-<key>。"
```

---

### Task 2: 本地化注入（92 动物名三语 + 新交互文案）

**Files:**
- Modify: `Shared/Localization/Localizable.xcstrings`（脚本注入）

**Interfaces:**
- Produces: key `animal.<key>`（92 个 × 3 语言）供图标选择器与随机命名使用；新 key：`common.copy` / `common.share` / `common.done` / `icon.graphic` / `icon.color` / `icon.randomColor` / `addplanet.randomIcon` / `qrcode.title`；`planet.add.title` 三语改为"添加行星服务器"；删除 `icon.reset`。

- [ ] **Step 1: 写注入脚本并执行**

仓库根目录执行（脚本为一次性，直接 heredoc，不落文件）：

```bash
cd /Users/zivyuan/GoziLib/Zerotier/planet-port-ios
python3 - <<'EOF'
import json

PATH = 'Shared/Localization/Localizable.xcstrings'
d = json.load(open(PATH))

def set_key(key, hans, hant, en):
    d['strings'][key] = {'localizations': {
        'zh-Hans': {'stringUnit': {'state': 'translated', 'value': hans}},
        'zh-Hant': {'stringUnit': {'state': 'translated', 'value': hant}},
        'en':      {'stringUnit': {'state': 'translated', 'value': en}},
    }}

# 92 个动物名(顺序与 catalog 一致)
ANIMALS = {
 'ant': ('蚂蚁','螞蟻','Ant'), 'anteater': ('食蚁兽','食蟻獸','Anteater'),
 'armadillo': ('犰狳','犰狳','Armadillo'), 'badger': ('獾','獾','Badger'),
 'bat': ('蝙蝠','蝙蝠','Bat'), 'beaver': ('河狸','河狸','Beaver'),
 'bee': ('蜜蜂','蜜蜂','Bee'), 'bird': ('鸟','鳥','Bird'),
 'bison': ('野牛','野牛','Bison'), 'boar': ('野猪','野豬','Boar'),
 'bug': ('臭虫','臭蟲','Bug'), 'bull': ('公牛','公牛','Bull'),
 'butterfly': ('蝴蝶','蝴蝶','Butterfly'), 'camel': ('骆驼','駱駝','Camel'),
 'cat': ('猫','貓','Cat'), 'cobra': ('眼镜蛇','眼鏡蛇','Cobra'),
 'cow': ('奶牛','奶牛','Cow'), 'crab': ('螃蟹','螃蟹','Crab'),
 'crow': ('乌鸦','烏鴉','Crow'), 'deer': ('鹿','鹿','Deer'),
 'dinosaur-rex': ('霸王龙','霸王龍','T-Rex'), 'dodo': ('渡渡鸟','渡渡鳥','Dodo'),
 'dog': ('狗','狗','Dog'), 'dolphin': ('海豚','海豚','Dolphin'),
 'donkey': ('驴','驢','Donkey'), 'dove': ('鸽子','鴿子','Dove'),
 'dragon': ('龙','龍','Dragon'), 'dragonfly': ('蜻蜓','蜻蜓','Dragonfly'),
 'duck': ('鸭子','鴨子','Duck'), 'eel': ('鳗鱼','鰻魚','Eel'),
 'elephant': ('大象','大象','Elephant'), 'fish': ('鱼','魚','Fish'),
 'flamingo': ('火烈鸟','火烈鳥','Flamingo'), 'fox': ('狐狸','狐狸','Fox'),
 'frog': ('青蛙','青蛙','Frog'), 'gecko': ('壁虎','壁虎','Gecko'),
 'goat': ('山羊','山羊','Goat'), 'goose': ('鹅','鵝','Goose'),
 'gorilla': ('大猩猩','大猩猩','Gorilla'), 'hedgehog': ('刺猬','刺蝟','Hedgehog'),
 'heron': ('苍鹭','蒼鷺','Heron'), 'hippo': ('河马','河馬','Hippo'),
 'horse': ('马','馬','Horse'), 'hummingbird': ('蜂鸟','蜂鳥','Hummingbird'),
 'ibis': ('朱鹮','朱鷺','Ibis'), 'jellyfish': ('水母','水母','Jellyfish'),
 'kangaroo': ('袋鼠','袋鼠','Kangaroo'), 'kiwi-bird': ('鹬鸵','鷸鴕','Kiwi'),
 'koala': ('考拉','無尾熊','Koala'), 'ladybug': ('瓢虫','瓢蟲','Ladybug'),
 'lion': ('狮子','獅子','Lion'), 'locust': ('蝗虫','蝗蟲','Locust'),
 'mammoth': ('猛犸象','猛獁象','Mammoth'), 'mole': ('鼹鼠','鼴鼠','Mole'),
 'monkey': ('猴子','猴子','Monkey'), 'mosquito': ('蚊子','蚊子','Mosquito'),
 'octopus': ('章鱼','章魚','Octopus'), 'ostrich': ('鸵鸟','鴕鳥','Ostrich'),
 'otter': ('水獭','水獺','Otter'), 'owl': ('猫头鹰','貓頭鷹','Owl'),
 'panda': ('熊猫','貓熊','Panda'), 'penguin': ('企鹅','企鵝','Penguin'),
 'pig': ('猪','豬','Pig'), 'piranha': ('食人鱼','食人魚','Piranha'),
 'polar-bear': ('北极熊','北極熊','Polar Bear'), 'rabbit': ('兔子','兔子','Rabbit'),
 'rattlesnake': ('响尾蛇','響尾蛇','Rattlesnake'), 'raven': ('渡鸦','渡鴉','Raven'),
 'rodent': ('啮齿动物','齧齒動物','Rodent'), 'rooster': ('公鸡','公雞','Rooster'),
 'scorpion': ('蝎子','蠍子','Scorpion'), 'seahorse': ('海马','海馬','Seahorse'),
 'seal': ('海豹','海豹','Seal'), 'shark': ('鲨鱼','鯊魚','Shark'),
 'sheep': ('绵羊','綿羊','Sheep'), 'shrimp': ('虾','蝦','Shrimp'),
 'sloth': ('树懒','樹懶','Sloth'), 'snail': ('蜗牛','蝸牛','Snail'),
 'snake': ('蛇','蛇','Snake'), 'sperm-whale': ('抹香鲸','抹香鯨','Sperm Whale'),
 'spider': ('蜘蛛','蜘蛛','Spider'), 'squid': ('鱿鱼','魷魚','Squid'),
 'squirrel': ('松鼠','松鼠','Squirrel'), 'swallow': ('燕子','燕子','Swallow'),
 'swan': ('天鹅','天鵝','Swan'), 'tiger': ('老虎','老虎','Tiger'),
 'tortoise': ('陆龟','陸龜','Tortoise'), 'turkey': ('火鸡','火雞','Turkey'),
 'turtle': ('乌龟','烏龜','Turtle'), 'unicorn': ('独角兽','獨角獸','Unicorn'),
 'vulture': ('秃鹫','禿鷲','Vulture'), 'worm': ('蚯蚓','蚯蚓','Worm'),
}
for key, (hans, hant, en) in ANIMALS.items():
    set_key('animal.' + key, hans, hant, en)

# 新交互文案
set_key('common.copy', '复制', '複製', 'Copy')
set_key('common.share', '分享', '分享', 'Share')
set_key('common.done', '完成', '完成', 'Done')
set_key('icon.graphic', '图形', '圖形', 'Shape')
set_key('icon.color', '底色', '底色', 'Background')
set_key('icon.randomColor', '随机底色', '隨機底色', 'Random Color')
set_key('addplanet.randomIcon', '换个随机图标', '換個隨機圖示', 'Randomize Icon')
set_key('qrcode.title', '二维码', 'QR Code', 'QR Code')
# 标题文案:添加行星 → 添加行星服务器(按钮 addplanet.action 已是新版,无需改)
set_key('planet.add.title', '添加行星服务器', '新增行星伺服器', 'Add Planet Server')

# 「恢复自动」入口已移除,删除对应 key
d['strings'].pop('icon.reset', None)

with open(PATH, 'w') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
    f.write('\n')
print('动物 key:', sum(1 for k in d['strings'] if k.startswith('animal.')))
EOF
```

- [ ] **Step 2: 验证注入结果**

```bash
python3 -c "
import json
d=json.load(open('/Users/zivyuan/GoziLib/Zerotier/planet-port-ios/Shared/Localization/Localizable.xcstrings'))
assert len([k for k in d['strings'] if k.startswith('animal.')])==92
assert 'icon.reset' not in d['strings']
print(d['strings']['animal.cat']['localizations']['zh-Hant']['stringUnit']['value'])  # 貓
print(d['strings']['planet.add.title']['localizations']['en']['stringUnit']['value']) # Add Planet Server
"
```

预期输出：`貓` 与 `Add Planet Server`。

- [ ] **Step 3: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 4: Commit**

```bash
git --no-pager add Shared/Localization/Localizable.xcstrings
git --no-pager commit -m "feat(i18n): 92 个动物名三语与图标设置/复制/二维码新文案

animal.<key> 供图标选择器与随机命名共用;新增图形/底色分段、
随机底色、复制/分享/完成、二维码等 key;标题改为「添加行星服务器」;
删除已无入口的「恢复自动」(icon.reset)。"
```

---

### Task 3: 数据模型与 PlanetIcon 重构

**Files:**
- Modify: `Shared/Models.swift:68`（icon 注释 + 新增 iconColor 字段）
- Rewrite: `PlanetPort/Views/PlanetIcon.swift`
- Modify: `PlanetPort/PlanetImporter.swift`（importPlanetData / updateIcon 签名）
- Modify: `PlanetPort/Views/PlanetCardView.swift:76-83`（iconTile 私有行星分支）
- Modify: `PlanetPort/Views/PlanetSettingsView.swift:100-103`（图标行小预览）

**Interfaces:**
- Produces（后续任务依赖的精确签名）:
  - `PlanetIcon.catalog: [String]`（92 个动物 key）
  - `PlanetIcon.animalKey(for planet: PlanetProfile) -> String`
  - `PlanetIcon.assetName(for planet: PlanetProfile) -> String`（返回 `"animal-<key>"`）
  - `PlanetIcon.tint(for planet: PlanetProfile) -> Color`
  - `PlanetIcon.randomColorHex() -> String`
  - `PlanetIcon.randomAnimal(excludingNames used: Set<String> = []) -> String`
  - `Color(hex: String)?` 初始化器（`#RRGGBB`）
  - `PlanetImporter.importPlanetData(_ data: Data, name: String, icon: String? = nil, iconColor: String? = nil) throws -> PlanetProfile`
  - `PlanetImporter.updateIcon(_ profile: PlanetProfile, icon: String?, color: String?) throws`
  - `PlanetProfile.iconColor: String?`

- [ ] **Step 1: Models.swift 增加字段**

`Shared/Models.swift` 中 `PlanetProfile`：

```swift
    /// 自定义图标名。语义:动物 key(如 "cat",对应 Assets 的 animal-cat.imageset);
    /// 有效 key 永久生效,未设置/旧值无效时按名称哈希回退(见 PlanetIcon)。
    var icon: String? = nil
    /// 自定义图标底色(#RRGGBB hex);nil 时按 id 哈希回退 ThemeManager tint。
    var iconColor: String? = nil
```

（原 `icon` 的 doc comment 一并替换为上面两段。）

- [ ] **Step 2: 重写 PlanetIcon.swift**

```swift
import SwiftUI

/// Planet 图标体系:动物矢量图标(Assets 中 animal-<key>,白色烧入 PDF)。
/// 图标 key 用户设置过则永久生效;否则按名称 djb2 哈希确定性选动物
/// (名称不变则图标不变,同名行星同图标)。底色自定义 hex 优先,
/// 否则按 id 哈希取 ThemeManager tint(已存在行星颜色不变)。
/// 官方行星与私有行星同规则,无特判。
enum PlanetIcon {
    /// 全部动物 key,与 Assets 中 animal-<key>.imageset 一一对应(92 个)。
    static let catalog: [String] = [
        "ant", "anteater", "armadillo", "badger", "bat", "beaver", "bee", "bird",
        "bison", "boar", "bug", "bull", "butterfly", "camel", "cat", "cobra",
        "cow", "crab", "crow", "deer", "dinosaur-rex", "dodo", "dog", "dolphin",
        "donkey", "dove", "dragon", "dragonfly", "duck", "eel", "elephant", "fish",
        "flamingo", "fox", "frog", "gecko", "goat", "goose", "gorilla", "hedgehog",
        "heron", "hippo", "horse", "hummingbird", "ibis", "jellyfish", "kangaroo",
        "kiwi-bird", "koala", "ladybug", "lion", "locust", "mammoth", "mole", "monkey",
        "mosquito", "octopus", "ostrich", "otter", "owl", "panda", "penguin", "pig",
        "piranha", "polar-bear", "rabbit", "rattlesnake", "raven", "rodent", "rooster",
        "scorpion", "seahorse", "seal", "shark", "sheep", "shrimp", "sloth", "snail",
        "snake", "sperm-whale", "spider", "squid", "squirrel", "swallow", "swan", "tiger",
        "tortoise", "turkey", "turtle", "unicorn", "vulture", "worm",
    ]

    /// 动物 key:有效自定义值永久生效;nil/旧值无效(SF Symbol 名)按名称哈希回退。
    static func animalKey(for planet: PlanetProfile) -> String {
        if let icon = planet.icon, catalog.contains(icon) { return icon }
        return catalog[djb2(of: planet.name) % catalog.count]
    }

    /// 图标资产名(animal- 前缀 imageset)。
    static func assetName(for planet: PlanetProfile) -> String {
        "animal-\(animalKey(for: planet))"
    }

    /// 底色:自定义 hex 优先(解析失败视为未设置),否则按 id 哈希回退 tint。
    static func tint(for planet: PlanetProfile) -> Color {
        if let hex = planet.iconColor, let color = Color(hex: hex) { return color }
        let tints = ThemeManager.shared.planetTints
        return tints[djb2(of: planet.id) % tints.count]
    }

    /// 随机底色 hex:随机色相 + 中低亮度域(饱和度 0.45–0.85、亮度 0.32–0.55),
    /// 白色图形对比度有保证。
    static func randomColorHex() -> String {
        hex(hue: .random(in: 0..<360),
            saturation: .random(in: 0.45...0.85),
            lightness: .random(in: 0.32...0.55))
    }

    /// 随机动物:优先排除本地化名与现有行星名相同的 key(名称建议与图标同源)。
    static func randomAnimal(excludingNames used: Set<String> = []) -> String {
        let candidates = catalog.filter { !used.contains(localizedName($0)) }
        return (candidates.isEmpty ? catalog : candidates).randomElement() ?? catalog[0]
    }

    /// 动物本地化名(animal.<key> 查表)。动态 key 须先拼 String 再构造
    /// LocalizationValue,避免字符串插值被当作格式化键。
    static func localizedName(_ key: String) -> String {
        loc(String.LocalizationValue("animal.\(key)"))
    }

    /// HSL → "#rrggbb"(小写)。h∈[0,360) s,l∈[0,1]。
    private static func hex(hue: Double, saturation: Double, lightness: Double) -> String {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = hue / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = lightness - c / 2
        func channel(_ v: Double) -> Int {
            min(max(Int(((v + m) * 255).rounded()), 0), 255)
        }
        return String(format: "#%02x%02x%02x", channel(r1), channel(g1), channel(b1))
    }

    /// djb2 哈希:同一输入永远同一结果。
    private static func djb2(of string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash % 1_000_003)
    }
}

extension Color {
    /// "#RRGGBB" 解析;非法输入返回 nil。
    init?(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
```

- [ ] **Step 3: PlanetImporter 签名调整**

`importPlanetData` 增加默认参数并落库（profile 构造行替换）：

```swift
    @discardableResult
    static func importPlanetData(_ data: Data, name: String,
                                 icon: String? = nil, iconColor: String? = nil) throws -> PlanetProfile {
```

```swift
        let profile = PlanetProfile(id: id, name: normalizedName, kind: .custom,
                                    fileName: fileName, icon: icon, iconColor: iconColor)
```

`updateIcon` 整体替换为：

```swift
    /// 更新自定义图标(动物 key)与底色 hex;icon 传 nil 表示未设置(按名称哈希回退)。
    static func updateIcon(_ profile: PlanetProfile, icon: String?, color: String?) throws {
        var profiles = AppConfigStore.readPlanets()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].icon = icon
        profiles[index].iconColor = color
        AppConfigStore.writePlanets(profiles)
    }
```

- [ ] **Step 4: 渲染调用点（PlanetCardView / PlanetSettingsView）**

`PlanetCardView.swift` `iconTile` 私有行星分支替换为：

```swift
        } else {
            Image(PlanetIcon.assetName(for: planet))
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .frame(width: 72, height: 72)
                .background(PlanetIcon.tint(for: planet),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
```

`PlanetSettingsView.swift` 图标行预览（`Image(systemName: PlanetIcon.symbol(for: planet))` 两行）替换为：

```swift
                            Image(PlanetIcon.assetName(for: planet))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .frame(width: 24, height: 24)
                                .background(PlanetIcon.tint(for: planet),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
```

（`PlanetIcon.symbol` 调用全仓仅此两处；替换后旧名不复存在。）

- [ ] **Step 5: 修复 updateIcon 旧调用**

`PlanetSettingsView.swift` sheet 回调中 `PlanetImporter.updateIcon(planet ?? .official, to: symbol)` 改为（Task 5 会重写整个 sheet，此处仅保证编译）：

```swift
                IconPickerSheet(current: planet?.icon ?? "") { symbol in
                    do {
                        try PlanetImporter.updateIcon(planet ?? .official, icon: symbol,
                                                      color: planet?.iconColor)
                        app.reloadConfig()
                    } catch {
                        alert = error.localizedDescription
                    }
                }
```

- [ ] **Step 6: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`（旧 IconPickerSheet 的 `Image(systemName:)` 传动物 key 只是不显示，编译不受影响）。

- [ ] **Step 7: Commit**

```bash
git --no-pager add Shared/Models.swift PlanetPort/Views/PlanetIcon.swift PlanetPort/PlanetImporter.swift PlanetPort/Views/PlanetCardView.swift PlanetPort/Views/PlanetSettingsView.swift
git --no-pager commit -m "feat(planet): 图标体系切换为动物 key + 自定义底色

icon 语义改为动物 key(有效值永久生效,未设置按名称 djb2 哈希
确定性回退);新增 iconColor(#RRGGBB,nil 时按 id 哈希回退 tint,
老行星颜色不变);PlanetIcon 提供 key/资产名/底色/随机底色/随机
动物接口;导入与设置落库同步带上图标与底色。"
```

---

### Task 4: CopyableValue / CopyableRow 公共组件

**Files:**
- Create: `PlanetPort/Views/CopyableValue.swift`

**Interfaces:**
- Produces:
  - `CopyableValue(text: String, showsIcon: Bool = true, font: Font = .system(.body, design: .monospaced), color: Color = .secondary, iconSize: CGFloat = 11)`
  - `CopyableRow(title: String, text: String, showsIcon: Bool = true, font: Font = .system(.body, design: .monospaced))`

- [ ] **Step 1: 新建组件文件**

```swift
import SwiftUI

/// 可复制值文本:点击(透明热区外扩 5pt,不改变布局)复制到剪贴板。
/// 可选常驻复制图标;复制成功后图标位置短暂变对勾(0.8s)。
/// 图标字号约为文字字高的 2/3(比例参照 NetworkCardView IP 复制图标:
/// 正文 11pt,caption2 用 9pt 由调用方传入)。
struct CopyableValue: View {
    let text: String
    /// 是否常驻复制图标;false 时仅复制成功瞬间显示对勾。
    var showsIcon: Bool = true
    var font: Font = .system(.body, design: .monospaced)
    var color: Color = .secondary
    var iconSize: CGFloat = 11
    /// 复制反馈:图标短暂变对勾。
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: iconSize, weight: copied ? .semibold : .regular))
                .foregroundStyle(copied ? AnyShapeStyle(ThemeManager.shared.success)
                                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .opacity(showsIcon || copied ? 1 : 0)
        }
        // 透明热区图层(外扩 5pt)承接点击:文字小字号时命中区不足。
        .overlay(
            Rectangle()
                .fill(Color.clear)
                .padding(-5)
                .contentShape(Rectangle())
                .onTapGesture(perform: copy)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("common.copy"))
        .accessibilityValue(Text(text))
    }

    private func copy() {
        guard !text.isEmpty, text != "—" else { return }
        UIPasteboard.general.string = text
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeIn(duration: 0.15)) { copied = false }
        }
    }
}

/// 详情页「标题 + 可复制值」行:标题左、值右,值整体可点复制。
struct CopyableRow: View {
    let title: String
    let text: String
    var showsIcon: Bool = true
    var font: Font = .system(.body, design: .monospaced)

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            CopyableValue(text: text, showsIcon: showsIcon, font: font)
        }
    }
}
```

- [ ] **Step 2: 构建验证（需先重新生成工程纳入新文件）**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 3: Commit**

```bash
git --no-pager add PlanetPort/Views/CopyableValue.swift
git --no-pager commit -m "feat(ui): 可复制值公共组件 CopyableValue/CopyableRow

点击复制 + 热区外扩 5pt + 成功瞬间对勾反馈,图标字号约为
文字字高 2/3;统一后续各详情页的复制交互。"
```

---

### Task 5: IconPickerSheet 重写（图形 / 底色）

**Files:**
- Rewrite: `PlanetPort/Views/IconPickerSheet.swift`
- Modify: `PlanetPort/Views/PlanetSettingsView.swift:42-51`（sheet 接线）

**Interfaces:**
- Consumes: `PlanetIcon.catalog` / `PlanetIcon.randomColorHex()` / `PlanetIcon.localizedName(_:)` / `Color(hex:)`（Task 3）；`animal-<key>` 资产（Task 1）；key `icon.graphic` / `icon.color` / `icon.randomColor` / `common.done`（Task 2）。
- Produces: `IconPickerSheet(animal: String, color: String?, onSelect: @escaping (String, String) -> Void)`；`IconPickerSheet.palette: [String]`（20 个预设底色 hex）。

- [ ] **Step 1: 重写 IconPickerSheet.swift**

```swift
import SwiftUI

/// 图标设置:分段「图形 / 底色」。图形页 4 列动物网格(深灰磁贴 + 本地化名 +
/// 选中标记);底色页当前预览 + 随机按钮 + 预设色板。选择后点「完成」统一生效。
/// 无「恢复自动」——图标一经选择永久使用,自动算法仅作未设置时的兜底。
struct IconPickerSheet: View {
    /// 当前动物 key(传有效解析结果,如 PlanetIcon.animalKey(for:))。
    let animal: String
    /// 当前底色 hex(nil = 未自定义)。
    let color: String?
    let onSelect: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .graphic
    @State private var selectedAnimal: String
    @State private var selectedColor: String

    enum Tab: Hashable { case graphic, color }

    /// 预设底色:中低亮度、白图形对比度可靠的色板。
    static let palette: [String] = [
        "#b03a3a", "#c0392b", "#d44037", "#c05621",
        "#b45309", "#a16207", "#854d0e", "#15803d",
        "#166534", "#0f766e", "#0e7490", "#155e75",
        "#1d4ed8", "#1e40af", "#3730a3", "#6d28d9",
        "#a21caf", "#9d174d", "#475569", "#334155",
    ]

    init(animal: String, color: String?, onSelect: @escaping (String, String) -> Void) {
        self.animal = animal
        self.color = color
        self.onSelect = onSelect
        _selectedAnimal = State(initialValue: animal)
        _selectedColor = State(initialValue: color ?? PlanetIcon.randomColorHex())
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("icon.title", selection: $tab) {
                    Text("icon.graphic").tag(Tab.graphic)
                    Text("icon.color").tag(Tab.color)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                ScrollView {
                    if tab == .graphic { animalGrid } else { colorGrid }
                }
                .padding(.top, 12)
            }
            .navigationTitle("icon.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onSelect(selectedAnimal, selectedColor)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 图形页

    private var animalGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(PlanetIcon.catalog, id: \.self) { key in
                Button {
                    selectedAnimal = key
                } label: {
                    VStack(spacing: 6) {
                        // 白色 PDF 需深色底才可见:统一中性深灰磁贴。
                        Image("animal-\(key)")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 48, height: 48)
                            .background(Color(white: 0.35),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(PlanetIcon.localizedName(key))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: key == selectedAnimal ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(key == selectedAnimal ? Color.accentColor : Color.clear)
                            .frame(height: 14)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        key == selectedAnimal
                            ? Color.accentColor.opacity(0.1)
                            : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    // MARK: - 底色页

    private var colorGrid: some View {
        VStack(spacing: 14) {
            // 当前预览:白动物图 + 预选底色。
            Image("animal-\(selectedAnimal)")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .frame(width: 72, height: 72)
                .background(Color(hex: selectedColor) ?? .gray,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                selectedColor = PlanetIcon.randomColorHex()
            } label: {
                Label("icon.randomColor", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        selectedColor = hex
                    } label: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(height: 44)
                            .overlay(alignment: .topTrailing) {
                                if hex == selectedColor {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}
```

- [ ] **Step 2: PlanetSettingsView sheet 接线**

`.sheet(isPresented: $showIconPicker)` 闭包替换为：

```swift
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(animal: PlanetIcon.animalKey(for: planet ?? .official),
                            color: planet?.iconColor) { animal, color in
                do {
                    try PlanetImporter.updateIcon(planet ?? .official, icon: animal, color: color)
                    app.reloadConfig()
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
```

- [ ] **Step 3: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 4: Commit**

```bash
git --no-pager add PlanetPort/Views/IconPickerSheet.swift PlanetPort/Views/PlanetSettingsView.swift
git --no-pager commit -m "feat(icon): 图标设置重写为「图形/底色」分段选择

图形页 4 列动物网格(深灰磁贴+本地化名+选中标记);底色页当前
预览+随机按钮+预设色板;完成统一生效;移除「恢复自动」入口。"
```

---

### Task 6: 新增行星页身份区重构

**Files:**
- Rewrite: `PlanetPort/Views/AddPlanetPage.swift`
- Modify: `PlanetPort/Views/AddPlanetForm.swift`（移除名称行、签名加 animal/colorHex、add() 落库、删 PlanetNameSuggest）
- Modify: `PlanetPort/Views/PlanetCardView.swift`（移除 isPreview 预览形态）

**Interfaces:**
- Consumes: `IconPickerSheet(animal:color:onSelect:)`（Task 5）；`PlanetIcon.randomAnimal(excludingNames:)` / `randomColorHex()` / `assetName(for:)` / `localizedName(_:)`（Task 3）；`importPlanetData(_:name:icon:iconColor:)`（Task 3）。
- Produces: `AddPlanetForm(name: Binding<String>, animal: String, colorHex: String, onImported:)`。

- [ ] **Step 1: 重写 AddPlanetPage.swift**

```swift
import SwiftUI

/// 末位"添加"页:身份预览区(图标 + 行内名称编辑 + 随机按钮)+ 大标题 + 内嵌表单,
/// 与行星页的布局语言刻意区分,一眼可辨"这是创建流程"。
/// 预览名称与 HomeView 共享(Binding):由本页生成/去重,父级无需参与。
struct AddPlanetPage: View {
    @EnvironmentObject private var app: AppState
    @Binding var previewName: String
    /// 是否停在本页(HomeView 传入 pagerSelection == addTag,与 FAB 隐藏同源)。
    let isCurrentPage: Bool
    /// 表单入场动画状态(false=下方 120pt 待入场)。
    @State private var formShown = false

    /// 身份状态:动物 key + 底色 hex。名称未被用户手动编辑前跟随动物本地化名。
    @State private var animal = PlanetIcon.randomAnimal()
    @State private var colorHex = PlanetIcon.randomColorHex()
    @State private var nameEditedByUser = false
    @State private var showIconSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                previewIdentity
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                header
                    .padding(.horizontal, 20)
                AddPlanetForm(name: $previewName, animal: animal, colorHex: colorHex) { profile in
                    app.reloadConfig()
                    app.selectPlanet(profile)
                    // 添加成功后重掷身份,避免与刚添加的行星同名/同图。
                    rollIdentity()
                }
                .padding(.horizontal, 20)
                .offset(y: formShown ? 0 : 120)
                .opacity(formShown ? 1 : 0)
            }
            .padding(.top, HomeMetrics.pageTopPadding)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.immediately)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if previewName.isEmpty { rollIdentity() }
        }
        .onChange(of: isCurrentPage) { current in
            if current {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.15)) {
                    formShown = true
                }
            } else {
                formShown = false
            }
        }
        .sheet(isPresented: $showIconSettings) {
            IconPickerSheet(animal: animal, color: colorHex) { newAnimal, newColor in
                animal = newAnimal
                colorHex = newColor
                syncNameWithAnimal()
            }
        }
    }

    /// 身份预览区:72pt 图标(点击弹图标设置)+ 行内名称编辑 + 随机按钮(重掷
    /// 图形+底色)。虚线边框沿用原预览语义:"尚未创建"的占位形态。
    private var previewIdentity: some View {
        VStack(spacing: 12) {
            Button {
                showIconSettings = true
            } label: {
                Image("animal-\(animal)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .frame(width: 72, height: 72)
                    .background(Color(hex: colorHex) ?? .gray,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.icon"))

            HStack(spacing: 8) {
                TextField(loc("addplanet.namePlaceholder"), text: $previewName)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: previewName) { newValue in
                        if newValue != PlanetIcon.localizedName(animal) {
                            nameEditedByUser = true
                        }
                    }
                Button {
                    rollIdentity()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.medium))
                        .frame(width: 38, height: 38)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("addplanet.randomIcon"))
            }
            .frame(maxWidth: 260)
        }
        .padding(14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
    }

    /// 标题:headline 主标题 + footnote 副指引,与行星页的低调计数行拉开层级。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("planet.add.title")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("addplanet.subtitle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 重掷身份:随机动物(本地化名与现有行星去重)+ 随机底色;名称未手动
    /// 编辑过则跟随动物本地化名。
    private func rollIdentity() {
        animal = PlanetIcon.randomAnimal(excludingNames: Set(app.planets.map(\.name)))
        colorHex = PlanetIcon.randomColorHex()
        nameEditedByUser = false
        previewName = PlanetIcon.localizedName(animal)
    }

    /// 手动选图形后:名称未手动编辑过则跟随(不去重,名称冲突由用户改名)。
    private func syncNameWithAnimal() {
        guard !nameEditedByUser else { return }
        previewName = PlanetIcon.localizedName(animal)
    }
}
```

- [ ] **Step 2: 修改 AddPlanetForm.swift**

结构体声明区替换（新增两属性）：

```swift
struct AddPlanetForm: View {
    /// 与首页 Pager 的预览卡片共享的名称(编辑已移至预览身份区,此处只读)。
    @Binding var name: String
    /// 身份(由预览区持有,添加时随名称一并落库)。
    let animal: String
    let colorHex: String
    let onImported: (PlanetProfile) -> Void
```

`formCard` 中删除整个「名称 + 随机换名」HStack（`field($name, ...)` 与 `arrow.triangle.2.circlepath` 按钮的 HStack 块），保留选择文件行与 URL 行。

`add()` 中 import 行替换为：

```swift
            let profile = try PlanetImporter.importPlanetData(data, name: trimmedName,
                                                              icon: animal, iconColor: colorHex)
```

文件末尾删除整个 `PlanetNameSuggest` enum（随机命名已改为动物名方案，逻辑在 AddPlanetPage.rollIdentity）。

- [ ] **Step 3: PlanetCardView 移除 isPreview**

`PlanetCardView.swift`：
1. 删除属性 `var isPreview = false`。
2. body 中 `.padding(.horizontal, isPreview ? 14 : 0)` / `.padding(.vertical, isPreview ? 14 : 0)` 两行删除。
3. body 中整个 `// 预览形态:虚线边框 + 淡底…` 的 `.background { if isPreview { ZStack { … } } }` 块删除。
4. `iconWithBadge` 中齿轮 overlay 的 `if !isPreview {` 条件去掉，齿轮直接显示。
5. 长按手势 `guard !isPreview else { return }` 改为直接 `pressed = pressing`。
6. `statusText`/`statusColor` 中 `if isPreview { return … }` 分支删除。

（预览形态已由 AddPlanetPage 自建身份区替代，PlanetCardView 回归纯展示。）

- [ ] **Step 4: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`（若 HomeView 有 isPreview 传参残留，编译错误会指出，一并删除该传参）。

- [ ] **Step 5: Commit**

```bash
git --no-pager add PlanetPort/Views/AddPlanetPage.swift PlanetPort/Views/AddPlanetForm.swift PlanetPort/Views/PlanetCardView.swift
git --no-pager commit -m "feat(addplanet): 身份区重构为图标+行内名称+随机按钮

72pt 图标点击弹图标设置,名称移到图标下方行内编辑,随机按钮
重掷图形+底色;名称未手动编辑时跟随动物本地化名(与现有行星
去重);表单名称输入框移除;随机星球名方案(PlanetNameSuggest)
移除;PlanetCardView 预览形态(isPreview)随预览卡替代而移除。"
```

---

### Task 7: 行星卡片 ID 行复制改造

**Files:**
- Modify: `PlanetPort/Views/PlanetCardView.swift:92-121`（idLine）

**Interfaces:**
- Consumes: `CopyableValue`（Task 4）。

- [ ] **Step 1: 替换 idLine**

删除 `@State private var copied` 属性与整个 `idLine` 实现，替换为：

```swift
    /// ID 等宽 tertiary(16pt);moon>0 时以间隔号「·」(U+00B7)跟随「卫星 x n」。
    /// 点击 ID 复制(热区外扩),无常驻复制图标,成功瞬间短暂显示对勾。
    private var idLine: some View {
        let nodeId = app.planetNodeIds[planet.id] ?? "-"
        return HStack(spacing: 4) {
            CopyableValue(text: nodeId,
                          showsIcon: false,
                          font: .system(size: 16, design: .monospaced),
                          color: .secondary)
            if moonCount > 0 {
                Text("·")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Text("planetcard.moonCount \(moonCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

- [ ] **Step 2: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 3: Commit**

```bash
git --no-pager add PlanetPort/Views/PlanetCardView.swift
git --no-pager commit -m "feat(planetcard): 节点 ID 改为点击复制并扩大热区

移除常驻复制图标,热区外扩 5pt 不改变布局,复制成功瞬间
短暂显示对勾反馈(复用 CopyableValue)。"
```

---

### Task 8: PlanetSettingsView（节点 ID 复制 / planet 文件分享）

**Files:**
- Modify: `PlanetPort/Views/PlanetSettingsView.swift`（infoSection）

**Interfaces:**
- Consumes: `CopyableRow` / `CopyableValue`（Task 4）；`AppGroup.planetsDir`。

- [ ] **Step 1: 节点 ID 行改可复制**

`infoSection` 中 `row(loc("planet.info.nodeId"), nodeIDText)` 替换为：

```swift
            CopyableRow(title: loc("planet.info.nodeId"), text: nodeIDText, showsIcon: false)
```

- [ ] **Step 2: planet 文件大小行加分享**

`infoSection` 中 `row(loc("planet.info.fileSize"), locFileSize(info.fileSize))` 替换为 `fileSizeRow(info)`，并新增实现：

```swift
            if let info = PlanetImporter.inspectPlanetFile(planet) {
                fileSizeRow(info)
                row(loc("planet.info.revision"), Self.timestampText(info.timestamp))
            }
```

```swift
    /// 文件大小行:值后附分享按钮(系统分享面板,可保存到"文件"/隔空投送等)。
    /// 文件不存在(并发删除)时不显示按钮。
    @ViewBuilder
    private func fileSizeRow(_ info: (worldId: UInt64, timestamp: UInt64, fileSize: Int)) -> some View {
        HStack {
            Text(loc("planet.info.fileSize"))
            Spacer()
            Text(locFileSize(info.fileSize))
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
            if let url = planetFileURL {
                ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("common.share"))
            }
        }
    }

    private var planetFileURL: URL? {
        guard let fileName = planet?.fileName else { return nil }
        let url = AppGroup.planetsDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
```

- [ ] **Step 3: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 4: Commit**

```bash
git --no-pager add PlanetPort/Views/PlanetSettingsView.swift
git --no-pager commit -m "feat(planet): 设置页节点 ID 点击复制与 planet 文件系统分享

节点 ID 行接入 CopyableRow;文件大小行追加分享图标,ShareLink
拉起系统分享面板(保存到文件/隔空投送),文件缺失时不显示。"
```

---

### Task 9: NetworkDetailView（网络 ID 二维码 / MAC 格式化 / IP 复制）

**Files:**
- Modify: `PlanetPort/Views/NetworkDetailView.swift`

**Interfaces:**
- Consumes: `CopyableRow` / `CopyableValue`（Task 4）；key `qrcode.title`（Task 2）。

- [ ] **Step 1: 网络ID / MAC 行改造**

新增 state 与替换行（`infoSection` 对应行）：

```swift
    @State private var showQR = false
```

`row(loc("network.id"), entry.networkId)` 替换为 `networkIdRow`；`row("MAC", snapshot?.mac ?? "—")` 替换为：

```swift
                CopyableRow(title: "MAC", text: macText)
```

新增实现：

```swift
    /// 网络 ID 行:点击复制 + 二维码分享入口。
    private var networkIdRow: some View {
        HStack {
            Text(loc("network.id"))
            Spacer()
            CopyableValue(text: entry.networkId)
            Button {
                showQR = true
            } label: {
                Image(systemName: "qrcode")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("qrcode.title"))
        }
    }

    /// MAC 常用格式 aa:bb:cc:dd:ee:ff(隧道进程传 12 位无分隔 hex,UI 层格式化)。
    private var macText: String {
        guard let raw = snapshot?.mac else { return "—" }
        return Self.formatMAC(raw)
    }

    static func formatMAC(_ raw: String) -> String {
        let hex = raw.lowercased()
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return raw }
        var result = ""
        for i in stride(from: 0, to: 12, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            result += i > 0 ? ":" : ""
            result += String(hex[start..<end])
        }
        return result
    }
```

- [ ] **Step 2: 分配 IP 行可复制**

```swift
            Section("network.assignedAddrs") {
                if let addrs = snapshot?.assignedAddrs, !addrs.isEmpty {
                    ForEach(addrs, id: \.self) { addr in
                        CopyableValue(text: addr)
                    }
                } else { Text("—") }
            }
```

- [ ] **Step 3: 二维码 sheet**

body 链上加 `.sheet(isPresented: $showQR) { NetworkQRSheet(entry: currentEntry, snapshot: snapshot) }`（放在 `.refreshable` 之后），并在文件底部新增：

```swift
/// 网络 ID 二维码分享 sheet:二维码(内容 = 网络 ID 纯文本,与 App 内扫码
/// 填 ID 互逆)+ 网络名称 + 网络 ID(点击/图标均可复制)。
private struct NetworkQRSheet: View {
    let entry: NetworkEntry
    let snapshot: NetworkConfigSnapshot?

    var body: some View {
        VStack(spacing: 16) {
            Text("qrcode.title")
                .font(.headline)
            if let image = Self.qrImage(for: entry.networkId) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            }
            let name = (snapshot?.name.isEmpty ?? true) ? entry.networkName : (snapshot?.name ?? "")
            VStack(spacing: 6) {
                Text(name.isEmpty ? entry.networkId : name)
                    .font(.subheadline.weight(.semibold))
                CopyableValue(text: entry.networkId,
                              font: .system(.footnote, design: .monospaced),
                              iconSize: 9)
            }
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    /// 系统 CIQRCodeGenerator 生成二维码位图,放大 10 倍保证清晰。
    static func qrImage(for string: String, scale: Int = 10) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
```

- [ ] **Step 4: 构建验证**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

- [ ] **Step 5: Commit**

```bash
git --no-pager add PlanetPort/Views/NetworkDetailView.swift
git --no-pager commit -m "feat(network): 网络详情复制交互与网络 ID 二维码

网络 ID 点击复制 + 二维码入口(CIQRCodeGenerator,内容为 ID
纯文本,与扫码填 ID 互逆);MAC 格式化为 aa:bb:cc:dd:ee:ff 并
可复制;分配 IP 逐行点击复制。"
```

---

### Task 10: 收尾（图标署名 + 全量验证）

**Files:**
- Modify: `README.md`、`README.en.md`（致谢段补图标来源署名）

**Interfaces:** 无代码接口。

- [ ] **Step 1: README 补图标署名**

两个 README 的致谢/许可段落各追加一行（CC BY 4.0 要求分发时署名；MDI 免署名但一并说明来源）：

中文：
> 部分动物图标来自 [Material Design Icons](https://pictogrammers.com/)（Pictogrammers Free License）与 [Font Awesome Free](https://fontawesome.com/)（CC BY 4.0，Icons by Font Awesome）。

英文：
> Some animal icons are from [Material Design Icons](https://pictogrammers.com/) (Pictogrammers Free License) and [Font Awesome Free](https://fontawesome.com/) (CC BY 4.0; Icons by Font Awesome).

- [ ] **Step 2: 全量构建 + 人工核对**

运行 `BUILD_CMD`。预期 `BUILD SUCCEEDED`。

模拟器人工核对清单（逐项）：
1. 新增页：图标在上、名称行内编辑、随机按钮重掷图形+底色；改过名称后随机不再覆盖名称。
2. 图标设置：图形/底色分段、动物名三语正确显示、完成生效；无「恢复自动」。
3. 老行星：升级后图标按名称哈希稳定（改名后动物随之变化）、底色不变。
4. 行星卡片：无常驻复制图标，点 ID 出对勾；moon 数不变。
5. 网络详情：ID 复制/二维码（扫码回读一致）、MAC 小写冒号格式、IP 复制。
6. 设置页：节点 ID 复制、planet 文件分享拉起系统面板、官方行星只读。
7. 三语切换检查新增文案。

- [ ] **Step 3: Commit**

```bash
git --no-pager add README.md README.en.md
git --no-pager commit -m "docs(readme): 动物图标来源署名

FA6 Free 为 CC BY 4.0,分发需署名;MDI 一并说明来源。"
```
