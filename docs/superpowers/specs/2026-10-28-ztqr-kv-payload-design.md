# ZTQR 载荷 KV 容器协议设计（ZTP）

## 背景与目标

二维码分享 planet 的载荷目前是裸 planet 文件字节（`QRTransfer.encode` 直接压缩数据），无任何结构，无法扩展。本设计将载荷升级为无序 KV 容器（magic `ZTP`），在 planet 二进制之外携带名称、图标、颜色编号等元数据，并建立永不失配的演进机制。

范围与前提：

- 仅改二维码传输路径的载荷格式；帧协议 `ZTQR1|...` 不动；文件/URL 导入路径不动（那是 ZeroTier 生态格式）。
- 已发版本的裸 planet 载荷**不做兼容**（未大面积下发，从零设计）。

## 演进哲学

版本不在格式层。wire format 一版定死，演进只发生在 key 空间；解析器永远只有一个：逐条扫描，认识的 key 就取，未知的按 len 定界跳过（杂讯免疫）。不存在「旧版读不了新版数据」——因为格式没有新版。

两条纪律，保证 wire format 永不被迫升级：

1. **嵌套结构用 key 空间解决**：某 key 的 value 内部再按 KV 解析，旧版把整个 value 当杂讯跳过。
2. **magic 不带数字**：`ZTP` 是格式标识，不是版本标识，语义是「这是 KV 容器」。

超长数据不通过同 key 多条目表达（len 已取 4 字节，单条目上限 4GB，planet 上限 64KB 远未触及）；将来若有超长需求，出路是新 key 或嵌套容器，而非同 key 重复。

## Wire Format

```
┌────────┬───────────────┬───────────────┬─────┐
│ "ZTP"  │ key len value │ key len value │ ... │
└────────┴───────────────┴───────────────┴─────┘
  3字节    1    4         1    4
          key  len(小端)
```

- `magic`：ASCII `"ZTP"`（3 字节）。
- `key`：1 字节数字，`0` 非法。
- `len`：4 字节小端，value 字节数。一步到位取 4 字节（2 字节恰好卡在 planet 理论上限 64KB 没余量），消除将来被迫改格式的风险。
- `value`：原始字节，含义由 key 约定（见字段表）。
- 条目**顺序无关**；未知 key 跳过；重复 key 取后出现的值——这是同 key 多条目的唯一语义，无拼接（生成端保证不产生重复）；数据尾即容器尾，无总长度字段。

解析端判定顺序与兜底语义：

| 情形 | 行为 |
|---|---|
| `ZTP` magic + 条目边界全部成立 | 解析出 `[key: value]` |
| `ZTP` magic 但某条目 len 越界（截断/损坏） | 返回 nil，调用方按数据损坏提示重扫 |
| 无 magic 且首字节非 `0x01` | 非 ZT 数据，提示无法识别 |
| `0x01` 开头（旧版裸 planet 载荷） | 同上，新版不识别（明确不做兼容） |
| planet 字段缺失 | 提示缺少行星数据 |

## Key 约定（应用层，非组件职责）

key 是否分区、语义如何定义，是具体应用层的事；组件（PayloadContainer）只负责按格式编解码，对 key 含义零假设。以下为 PlanetPort 应用层的 v1 约定：

| key | 字段 | value 编码 | 必备 |
|---|---|---|---|
| 1 | planet 二进制 | .planet 文件原始字节 | 是 |
| 2 | 名称 | UTF-8 | 否（发送端实际必带） |
| 3 | 图标 | UTF-8（动物 key） | 否 |
| 4 | 颜色编号 | UTF-8（hex） | 否 |

## 模块 API（QRTransfer 内新增，现有 API 不动）

```swift
/// ZTP KV 容器编解码。纯 wire format 层，对 key 含义零假设。
enum PayloadContainer {
    /// 字段列表 → 容器 Data
    static func encode(_ fields: [(UInt8, Data)]) -> Data
    /// 容器 Data → [key: value]；magic 不符或边界不成立 → nil
    static func decode(_ data: Data) -> [UInt8: Data]?
}
```

模块保持通用、零 App 依赖（pod-ready 原则不破）；key 常量与 `PlanetProfile ⇄ 字段` 的业务映射都放 App 层。`QRTransfer.encode/decode` 签名不变——容器只是喂给它的普通 `Data`。

## 接入层

**发送端**（PlanetSettingsView）：planet 文件字节 + 当前 profile 的 name/icon/iconColor → 组容器（名称必带；icon/iconColor 为 nil 时省略条目）→ `QRShareView(data:)`。

**接收端**（AddPlanetForm）：`QRReceiveView` 回调 `Data`（容器）→ App 层解析 → planet 字段经既有 `validate`（首字节 `0x01`）回填 `pendingData`；名称/图标/颜色**预填表单与首页预览区**，用户可修改，走现有「添加 + World ID 查重」流程；无元数据条目时字段留默认。解析 nil 按上表兜底提示。

预填涉及 `AddPlanetForm` 数据流调整：`name` 已是 Binding，`animal`/`colorHex` 目前由预览身份区持有，需让扫码结果可写入（实现计划细化）。

## 错误处理

- 容器解析 nil / planet 缺失：alert 提示，扫码层不自动关闭或重试聚合（与现状一致，用户重扫）。
- 名称为空：表单必填校验兜底（现有 `emptyName`），不新增逻辑。

## 测试

默认不写（全局规则 7.1）。上次 QRTransfer 纯逻辑测试为用户明确要求；本次容器解析同为纯逻辑，若需要可补：未知 key 跳过、重复 key 后值覆盖、截断/magic 不符返回 nil、字段往返。

## 明确不做

- 已发版本（裸 planet 载荷）兼容
- 字符串 key / `=` 分隔形式（自描述性被传输层封装遮蔽，显示层 pretty-print 可另做）
- 载荷版本号字段
