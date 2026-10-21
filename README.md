# PlanetPort

ZeroTier 1.16.2 非官方 iOS 客户端，个人自用，Xcode 直装。

## 功能

- 加入/退出 ZeroTier 网络，实时状态（在线、拒绝访问、需要认证等中文提示）
- 默认路由（经 ZT 路由）与 DNS 三模式（网络下发 / 自定义 / 不使用）可切换，隧道热重配
- 多 Planet：官方与多份私有 Planet 快速切换，支持文件/URL 导入、重命名和删除
- Network、Moon 与 Planet 关联，切换 Planet 时展示各自独立的列表与 Core 缓存
- Moon 节点：文件导入、手动 orbit、缓存管理
- 允许移动数据、禁用 IPv6、Connect On Demand（按需连接，对应 Android 开机自启）
- Peers 实时列表（角色 / 版本 / 延迟 / 物理路径）

## 架构

```
┌─ App (PlanetPort) ──────────────┐      ┌─ Extension (PlanetPortTunnel) ────┐
│ SwiftUI UI                         │      │ NEPacketTunnelProvider             │
│  NetworkList / Detail / Peers      │      │  ├─ ZTBridge (OC++) ── ZT 1.16.2   │
│  Moon / Prefs                      │      │  ├─ FrameConverter (L2↔L3)         │
│  VPNManager (NETunnelProviderMgr)  │      │  ├─ UDP 9994 收发                  │
└────────────┬───────────────────────┘      │  └─ ARP/NDP 软件表                 │
             │  App Group + Darwin notify   └────────────┬──────────────────────┘
             │  (配置变更 / 状态回传)                     │ sendProviderMessage
             └───────────────────────────────────────────┘ (实时查询: peers/status/netconf)
```

- **核心**：ZeroTier 1.16.2 C API 跑在 extension 进程，stateGet/statePut 落 App Group 容器
- **Planet 隔离**：`ZT_STATE_OBJECT_PLANET` 按当前配置重定向；Network/Moon/Peer Core 缓存按 Planet 分目录
- **帧语义**：C API 帧不含以太网头（MAC/etherType 为独立参数），FrameConverter 负责与 NEPacketTunnelProvider 的 L3 IP 包互转，ARP/NDP 为纯软件表
- **组播**：broadcast + ADI=本机 IPv4 软件订阅（无 PacketMixin）

## 目录

- `Core/` — ZeroTier 1.16.2 核心源码（node/ + osdep 子集 + json/prometheus 头）
- `ZTBridge/` — OC++ 桥接层（C API ↔ Swift）
- `PlanetPortTunnel/` — 隧道 extension（帧转换、UDP、后台任务驱动）
- `Shared/` — App/Extension 共用（App Group、配置存储、IPC 模型、状态）
- `PlanetPort/` — 主 App（UI、VPNManager、导入器）

## 构建

```bash
brew install xcodegen   # 首次
xcodegen generate
open PlanetPort.xcodeproj
# Xcode 中选择自己的开发团队（主 target 与 tunnel extension 都要设）
# 真机连接后 Cmd+R 运行主 target（extension 随主 App 嵌入安装）
```

依赖的 entitlements 已在 project.yml 声明：App Groups (`group.cn.imgozi.PlanetPortI`)、Packet Tunnel Provider（个人账号可用）。

## 真机验证清单

1. **安装与授权**：Cmd+R 安装，首次启动 VPN 弹系统授权 → 允许
2. **生成身份**：启动后状态栏出现 10 位节点 ID；到 my.zerotier.com 授权该新节点
3. **加入网络**：输入 16 位网络 ID 加入 → 状态变「在线」，分到 managed IP，互 ping 通
4. **默认路由开关**：详情页开「经 ZT 路由」→ 路由表出现 default 经 utun；关 → 恢复（不重启隧道）
5. **DNS 模式**：切「自定义」填 DNS → `settings.dnsSettings` 生效（可访问内网域名验证）
6. **切换 Planet**：顶部选择另一 Planet 仅切换列表；打开其网络开关后才切换隧道并连接
7. **Moon**：导入 .moon 文件（或手动填 worldId/seed）→ Peers 页出现 MOON 角色
8. **Connect On Demand**：开启后锁屏/切网自动重连；关闭后手动启停
9. **禁用 IPv6**：开启后网络详情无 IPv6 地址下发到 tun
10. **重启恢复**：杀 App、重启手机 → 隧道按 lastActivated 恢复已连接网络

## 已知限制

- 未导入 Android identity（新节点需在 ZeroTier Central 重新授权）
- 蜂窝提示为占位（未实现 NWPathMonitor 实时判断）
