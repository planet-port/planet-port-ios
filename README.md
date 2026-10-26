# Planet Port 🪐

[English](README.en.md) | 中文

**Planet Port** 是一个建立在 [ZeroTier](https://www.zerotier.com) 之上的 iOS 网络连接管理层：不自己发明网络，而是把 ZeroTier 的连接能力包装成好用、可控、可定制的 App——多份根服务器（Planet）随身切换、多网络同时连接、Moon 节点、按需连接，以及完整的主题定制。免费开源，基于 2024 年底重新开源的 ZeroTier 1.16 核心（MPL-2.0）。

> 非官方客户端，与 ZeroTier, Inc. 无隶属关系。

## 特色

- **多 Planet 管理**：官方与多份私有 Planet 并存，文件/URL 导入、重命名、删除；切换 Planet 即切换整套网络列表与核心缓存，根服务器随身携带
- **多网络同时连接**：软上限（默认 2，可调 2–6）带确认放行；地址/网段冲突自动检测并断开，卡片上直接给出冲突原因
- **完整网络管理**：加入/退出网络，实时状态中文提示（在线、待授权、拒绝访问等），managed IP 一键复制
- **默认路由与 DNS 三模式**：经 ZT 路由开关、DNS 网络下发/自定义/不使用，全部隧道内热重配，无需重连
- **Moon 节点**：.moon 文件导入、手动 orbit、缓存管理
- **按需连接（Connect On Demand）**：锁屏、切网自动重连；允许移动数据、禁用 IPv6 细粒度控制
- **Peers 实时列表**：角色/版本/延迟/物理路径，延迟分级着色
- **主题定制**：预设国画经典色板（藤黄、竹青、石绿、群青、花青、黛、胭脂）+ 自定义拾色器，主色派生全局视觉（含行星装饰盘与状态色）
- **原生 SwiftUI**，界面纯中文，无任何遥测

## 核心用法

1. **安装**：克隆仓库 → `./scripts/bootstrap.sh`（自动拉取 ZeroTier 核心源码并生成 Xcode 工程）→ Xcode 选择自己的开发团队（主 target 与 tunnel extension 都要设）→ 真机 Cmd+R。个人（免费）Apple 开发者账号即可。
2. **加入网络**：首页添加行星（或使用官方 Planet）→ 输入 16 位网络 ID → 到 [ZeroTier Central](https://my.zerotier.com) 授权新节点 → 状态变「在线」即互通。
3. **切换 Planet**：导入私有 Planet 文件/URL → 首页左右翻页切换行星 → 打开其下网络开关即切换隧道。
4. **按需连接**：设置页开启 Connect On Demand，网络变化自动恢复连接。

### 命令行构建

```bash
brew install xcodegen   # 首次
./scripts/bootstrap.sh
open PlanetPort.xcodeproj
```

`bootstrap.sh` 会按固定 tag（含 SHA256 校验）从 ZeroTier 官方仓库下载核心源码到 `Core/`（已 gitignore，不入库），缓存于 `~/Library/Caches/PlanetPort/`，重跑秒过。下载失败时：

```bash
# 换镜像
ZT_TARBALL_URL=<镜像地址> ./scripts/bootstrap.sh
# 或浏览器手动下载 tarball 放到缓存目录后重跑（校验通过即离线使用）
mkdir -p ~/Library/Caches/PlanetPort
cp ZeroTierOne-1.16.2.tar.gz ~/Library/Caches/PlanetPort/
```

升级 ZeroTier 版本：修改 `scripts/bootstrap.sh` 中的 `ZT_VERSION` 与 `ZT_SHA256` 后重跑。

## 截图

<!-- TODO: 补充首页/添加行星/设置页截图 -->

## 架构

```
┌─ App (Planet Port) ──────────────┐      ┌─ Extension (PlanetPortTunnel) ────┐
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
- **Planet 隔离**：`ZT_STATE_OBJECT_PLANET` 按当前配置重定向；Network/Moon/Peer 核心缓存按 Planet 分目录
- **帧语义**：C API 帧不含以太网头（MAC/etherType 为独立参数），FrameConverter 负责与 NEPacketTunnelProvider 的 L3 IP 包互转，ARP/NDP 为纯软件表

### 目录

- `Core/` — ZeroTier 1.16.2 核心源码（构建时由 `scripts/bootstrap.sh` 按官方 tag 拉取，不入库；MPL-2.0，见 `docs/licenses/ZeroTierOne-MPL-2.0.txt`）
- `ZTBridge/` — OC++ 桥接层（C API ↔ Swift）
- `PlanetPortTunnel/` — 隧道 extension（帧转换、UDP、后台任务驱动）
- `Shared/` — App/Extension 共用（App Group、配置存储、IPC 模型、状态）
- `PlanetPort/` — 主 App（UI、VPNManager、导入器）

## 协议

- 本项目自有代码以 [MIT](LICENSE) 发布：免费使用，借用或引用请署名，再无其它限制
- `Core/` 内 ZeroTier 核心源码（构建时按官方 tag 拉取）为第三方代码，保持其原始 [MPL-2.0](docs/licenses/ZeroTierOne-MPL-2.0.txt) 协议，版权归 ZeroTier, Inc. 所有

### 致谢

- [ZeroTier](https://github.com/zerotier/ZeroTier) — 网络核心
- 部分动物图标来自 [Material Design Icons](https://pictogrammers.com/)（Pictogrammers Free License）与 [Font Awesome Free](https://fontawesome.com/)（CC BY 4.0，Icons by Font Awesome）。

## 捐赠

如果 Planet Port 帮到了你，欢迎请作者喝杯咖啡 ☕

<!-- TODO: 替换为真实收款码图片（docs/donate/ 下） -->
| 支付宝 | 微信 |
|:---:|:---:|
| ![支付宝](docs/donate/alipay.png) | ![微信](docs/donate/wechat.png) |

- **BTC**：`TODO_钱包地址`
- **ETH**：`TODO_钱包地址`
- **爱发电**：[TODO_主页链接](https://afdian.com)

## 已知限制

- 未导入已有 ZeroTier 身份（新节点需在 ZeroTier Central 重新授权）
- 蜂窝网络提示为固定占位（未实时判断当前链路类型）
- App Store 未上架，需自行源码构建安装
