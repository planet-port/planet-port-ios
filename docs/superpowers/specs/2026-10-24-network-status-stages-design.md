# 网络状态细化：连接服务器 → 请求网络配置 → 在线 设计文档

日期：2026-10-24
分支：feature/network-status-stages（基于 dev）

## 背景与动机

网络卡片的"正在初始化"对应 ZeroTier 核心的 `REQUESTING_CONFIGURATION` 状态，
覆盖"联系行星根服务器 → 定位控制器 → 拉取网络配置"整条等待链。正常时仅持续
1~2 秒；一旦物理网络故障（局域网干扰、蜂窝权限被拒等），核心无限重试，状态
永远停在"正在初始化"。该文案暗示"本地、短暂、正常"，用户无法察觉已发生故障，
VPN 长期空跑。

## 目标

1. 拆分状态展示：连接服务器 → 请求网络配置 → 在线。
2. 连接服务器阶段超过 30 秒判定为连接超时，自动进入关闭流程；无剩余启用
   网络时自动停止 VPN。
3. 超时断开后卡片显示断开原因"连接超时"。

## 状态机

```
开启网络（VPN 启动）
  ├─ online == false，耗时 < 30s  → "连接服务器"（橙）
  ├─ online == false，耗时 ≥ 30s  → "连接超时"（红）→ 触发自动关闭（瞬态）
  ├─ online == true               → "请求网络配置"（橙）
  └─ status == .ok                → "在线"（绿，现状不变）
```

- `online` 来自核心 ONLINE/OFFLINE 事件（`StatusStore.online`），表示已连通
  至少一台行星根服务器，是 VPN 级共享状态。
- VPN 运行中再开新网络（快速路径，不重启 VPN）：online 已为 true，直接从
  "请求网络配置"开始，不走 30 秒等待。

## 超时自动关闭

- **计时位置**：App 侧（用户已确认）。实现简单、关闭流程与冲突自动断开
  （AppState.handleConflicts）同构；代价是 App 后台挂起期间计时冻结，回前台
  补触发，后台期间 VPN 空跑（不劣于现状）。
- **计时器**：AppState 在 `vpnRunning` 翻转为 true 且 `!online` 时启动；
  online 变 true 或 VPN 停止时取消。
- **触发动作**（到点仍 `!online`）：
  1. 当前行星所有 `lastActivated` 网络：`lastActivated = false`、
     `lastConflict = "timeout"`（新原始码，与 `"address"`/`"subnet"` 同级）；
  2. 写配置（AppConfigStore.writeNetworks），Extension 随配置通知 leave；
  3. 无剩余启用网络 → `VPNManager.shared.stop()`。
- **超时范围**：全部启用网络一起关闭（服务器连不上是共享故障，用户已确认）。
- **后台补偿**：App 挂起期间计时冻结；回前台（scenePhase 变 active）或收到
  状态变更通知时重算"已耗时 ≥ 30s 且仍 offline"补触发。冷启动时若 VPN 已在
  跑且 offline，从 App 首次观察到时起算。

## 断开原因展示

复用 `lastConflict` 机制：手动重新开启时清除记录（现状行为）。展示文案层
新增 `"timeout"` 原始码的映射，显示"连接超时"（简短、准确）。

## 文案（Localizable.xcstrings 新增 3 键）

| 键 | 值 |
|---|---|
| `network.status.connectingServer` | 连接服务器 |
| `network.status.requestingConfig` | 请求网络配置 |
| `card.timeout.offline` | 连接超时 |

## 改动面

| 文件 | 改动 |
|---|---|
| PlanetPort/AppState.swift | 30s 计时器、超时关闭流程、online/vpnRunning 边沿监听、前台补偿 |
| PlanetPort/Views/NetworkCardView.swift | REQUESTING_CONFIGURATION 按 online/耗时拆分展示分支 |
| Shared/Models.swift | `lastConflict` 展示映射支持 `"timeout"` |
| Shared/Localization/Localizable.xcstrings | 新增 3 键 |

Extension（PlanetPortTunnel）不改动。

## 已知边界（接受，不处理）

- 核心因网络切换重启（PacketTunnelProvider "core restarted on network change"）
  时计时器不重置——初始连接 30 秒内恰好切换物理网络可能提前关闭，极端场景。
- "请求网络配置"阶段不设超时：控制器响应慢、首次加入待授权均属正常长等待。
- 30 秒为命名常量（如 `AppState.connectTimeout`），当前固定值，不做设置项。
