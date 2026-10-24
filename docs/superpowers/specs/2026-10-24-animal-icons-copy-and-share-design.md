# 动物图标体系与复制/分享交互改造 · 设计文档

日期：2026-10-24
状态：已确认（用户批准）

## 背景与目标

- 图标体系从 SF Symbol 换为 92 个动物图标（SVG 原稿在 `../Resources/ios/design/animals/` ，已移出仓库），白色矢量、随机底色，名称随机建议复用动物本地化名。
- 新增行星页身份区重构：图标在上、名称行内编辑在下、随机按钮重掷图形+底色。
- 全局补齐复制交互（ID/MAC/IP/节点 ID）、网络 ID 二维码分享、planet 文件系统分享。

## 一、图标资产管线

1. 转换脚本（一次性工具，放 `../Resources/ios/design/animals/convert-to-pdf.sh`（与源图同目录））：`fill="currentColor"` 替换为 `#FFFFFF`，`rsvg-convert -f pdf` 输出矢量 PDF（工具链：`brew install librsvg`）。
2. 生成 92 个 imageset：命名 `animal-<key>`（key 即文件名去扩展名，如 `animal-cat`），single scale、Preserve Vector Data。白色直接烧进 PDF（非 template 渲染；若日后需动态换色再改 template）。
3. 动物名本地化：`Localizable.xcstrings` 新增 `animal.<key>` × 92 × 3 语言（zh-Hans / zh-Hant / en）。选择器展示与随机命名共用同一 key。翻译须准确（如 anteater=食蚁兽/食蟻獸/Anteater）。

## 二、数据模型与图标体系

`Shared/Models.swift` / `PlanetPort/Views/PlanetIcon.swift`：

- `PlanetProfile.icon: String?` 语义变更：存动物 key（如 `"cat"`）。有有效动物 key（用户主动设置过）→ 永远使用该值，不再走任何自动。解码兼容：nil 或旧值不在动物表（SF Symbol 名）→ 视为未设置，按**名称**哈希确定性选一个动物（名称不变则动物不变；同名行星得到同一动物）。无需迁移脚本。
- 新增 `PlanetProfile.iconColor: String?`（hex，如 `"#D44037"`）。nil → 回退 ThemeManager tint 按 id 哈希（已存在行星外观不变）。Codable 可选新字段，老数据解码正常。
- 随机底色：随机 HSL，饱和度 0.45–0.85、亮度 0.32–0.55，转 hex 存储；白图形对比度有保证。
- `PlanetIcon.catalog` 换为 92 个动物 key；`symbol(for:)` 更名/改返回动物 key，回退哈希源为名称；底色回退哈希源保持 id（老行星颜色不变）；官方行星与私有行星同规则（名称哈希回退、底色 id 哈希），无特判（原官方磁贴方案已废弃丢弃）。

## 三、新增行星页面（AddPlanetPage / AddPlanetForm）

- 预览卡片（PlanetCardView 预览形态）改为：72pt 图标（点击弹出图标设置 sheet）→ 图标下方行内名称编辑框（居中）→ 名称右侧随机按钮（`arrow.triangle.2.circlepath`，重掷图形+底色）。预览形态不显示 ID 行。
- 表单中原名称输入框移除；名称初始值 = 随机动物的本地化名（与已有行星名去重，重名时换下一个候选）。
- 名称跟随：新增页本地状态 `nameEditedByUser`。选/随机图形时若为 false，名称自动跟随动物本地化名；用户手动编辑后置 true，不再跟随。
- 图标设置 sheet（IconPickerSheet 重写）：顶部分段控件「图形 / 底色」。图形页 4 列网格（白动物图 + 本地化名 + 选中标记）；底色页预设色板网格 + 随机按钮。移除「恢复自动」按钮——自动按名称/哈希出图标的算法入口彻底去掉（哈希回退仅为老数据兜底，无 UI 入口）。
- 「添加行星」文案改「添加行星服务器」（三语，含相关 title/subtitle 检查）。
- 设置页（PlanetSettingsView）图标行换用新选择器，小预览改为「底色块 + 白动物图」；名称编辑行保留。

## 四、复制 / 二维码 / 分享交互

抽公共组件 `CopyableValue`（值文本 + 可选常驻复制图标 + 点击复制；复制成功瞬间图标变对勾，0.8s 恢复；图标尺寸 ≈ 文字字高的 2/3，比例参照 NetworkCardView IP 复制图标）。

| 位置 | 行为 |
|---|---|
| 行星卡片 ID 行（PlanetCardView） | 移除常驻复制图标；ID 文字点击复制，透明热区外扩 5pt（不改变布局），成功瞬间短暂显示对勾 |
| 网络详情-网络 ID（NetworkDetailView） | 点击复制；值后加二维码图标 → sheet：二维码（内容 = 网络 ID 纯文本，与 App 内扫码填 ID 互逆）+ 网络名称 + 网络 ID（点击/复制图标均可复制）。二维码用系统 `CIQRCodeGenerator` 生成 |
| 网络详情-MAC | UI 层格式化为 `aa:bb:cc:dd:ee:ff`（小写冒号分隔；隧道进程仍传 12 位 hex），加复制图标 |
| 网络详情-分配 IP | 每个 IP 行点击复制 |
| 设置页-节点 ID（PlanetSettingsView） | 点击复制 |
| 设置页-planet 文件 | 文件大小后加分享图标，`ShareLink(item: fileURL)`（iOS 17 系统分享面板：存到「文件」/隔空投送等，不自研） |

### planet 文件二维码：分析结论（不实现）

planet 为二进制（几百字节～数 KB），QR 二进制上限 2953B；接收方扫码得到不可读二进制需专门解码落盘，现有扫码器只识别文本网络 ID。体积稍大即超限、体验远差于 ShareLink 文件分享。**结论：不做。**

## 边界与错误处理

- 动物 key 解析失败/资产缺失：回退哈希动物（保证有图可渲染）。
- `iconColor` hex 解析失败：回退 tint 哈希色。
- ShareLink 的 planet 文件位于 App Group `datastore/planets/`，分享面板直接读该 URL；文件被删（并发删除）时图标隐藏。
- 官方行星（kind == .official）图标/底色与私有行星同规则；其只读与不可删除逻辑不变。

## 验证方式

不新增自动化测试（遵循项目约定）。验证：`xcodegen` 重新生成工程后 `xcodebuild` 编译通过 + 模拟器人工核对各页面交互（新增页身份区/图标选择/复制反馈/二维码/分享面板）与三语文案。
