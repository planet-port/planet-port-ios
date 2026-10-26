# Planet Port 🪐

English | [中文](README.md)

**Planet Port** is an iOS network connection management layer built on top of [ZeroTier](https://www.zerotier.com). It doesn't reinvent networking — it wraps ZeroTier's connectivity into an app that is easy to use, controllable and customizable: carry multiple root servers (Planets) in your pocket, connect to several networks at once, manage Moon nodes and custom roots, connect on demand, and theme the whole app to your taste. Free and open source, powered by the ZeroTier 1.16 core re-open-sourced in late 2024 (MPL-2.0).

> Unofficial client. Not affiliated with ZeroTier, Inc.

## Highlights

- **Multi-Planet management** — keep the official and multiple private Planets side by side; import via file/URL, rename, delete. Switching Planet switches the entire network list and core caches; your root server travels with you
- **Multi-network connectivity** — soft limit (default 2, adjustable 2–6) with explicit confirmation; address/subnet conflicts are detected automatically and disconnected, with the reason shown right on the card
- **Full network management** — join/leave networks with live Chinese-language status (online, pending authorization, access denied…), one-tap managed-IP copy
- **Default route & DNS modes** — route-through-ZT toggle and three DNS modes (network-provided / custom / none), all hot-reconfigured inside the tunnel, no reconnect needed
- **Moon nodes** — .moon file import, manual orbit, cache management
- **Connect On Demand** — auto-reconnect on lock screen or network change; fine-grained cellular and IPv6 controls
- **Live Peers list** — role/version/latency/physical path, latency-graded coloring
- **Theming** — presets drawn from classical Chinese painting pigments (gamboge, bamboo green, malachite, ultramarine, indigo, dai, carmine) plus a custom color picker; the whole visual system (including planet decorations and status colors) derives from your main color
- **Native SwiftUI**, fully Chinese UI, zero telemetry

## Getting Started

1. **Install**: clone the repo → `./scripts/bootstrap.sh` (fetches the ZeroTier core sources and generates the Xcode project) → select your own development team in Xcode (for both the main target and the tunnel extension) → Cmd+R on device. A personal (free) Apple developer account is enough.
2. **Join a network**: add a Planet on the home page (or use the official one) → enter the 16-digit network ID → authorize the new node at [ZeroTier Central](https://my.zerotier.com) → the status turns "online" and you're connected.
3. **Switch Planets**: import a private Planet file/URL → swipe between planets on the home page → flip on one of its networks to switch the tunnel.
4. **On demand**: enable Connect On Demand in Settings; connections survive network changes.

### Building from the command line

```bash
brew install xcodegen   # first time
./scripts/bootstrap.sh
open PlanetPort.xcodeproj
```

`bootstrap.sh` downloads the ZeroTier core sources (pinned tag, SHA256-verified) from the official repository into `Core/` (gitignored, never committed), cached under `~/Library/Caches/PlanetPort/` — reruns are instant. If the download fails:

```bash
# use a mirror
ZT_TARBALL_URL=<mirror-url> ./scripts/bootstrap.sh
# or download the tarball manually into the cache directory and rerun (works offline once verified)
mkdir -p ~/Library/Caches/PlanetPort
cp ZeroTierOne-1.16.2.tar.gz ~/Library/Caches/PlanetPort/
```

To upgrade the ZeroTier version: update `ZT_VERSION` and `ZT_SHA256` in `scripts/bootstrap.sh` and rerun.

## Screenshots

<!-- TODO: home / add-planet / settings screenshots -->

## Architecture

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

- **Core**: the ZeroTier 1.16.2 C API runs inside the extension process; stateGet/statePut land in the App Group container
- **Planet isolation**: `ZT_STATE_OBJECT_PLANET` is redirected per current config; Network/Moon/Peer core caches live in per-Planet directories
- **Frame semantics**: C API frames carry no Ethernet header (MAC/etherType are separate parameters); FrameConverter bridges them to NEPacketTunnelProvider L3 IP packets, with pure-software ARP/NDP tables

### Layout

- `Core/` — ZeroTier 1.16.2 core sources (fetched at build time from the official tag by `scripts/bootstrap.sh`, not committed; MPL-2.0, see `docs/licenses/ZeroTierOne-MPL-2.0.txt`)
- `ZTBridge/` — OC++ bridging layer (C API ↔ Swift)
- `PlanetPortTunnel/` — tunnel extension (frame conversion, UDP, background task driving)
- `Shared/` — shared between App/Extension (App Group, config storage, IPC models, status)
- `PlanetPort/` — the main app (UI, VPNManager, importers)

## License

- This project's own code is released under the [MIT License](LICENSE): free to use; attribution is required when borrowing or referencing; no other restrictions
- The ZeroTier core sources under `Core/` (fetched at build time from the official tag) are third-party code under their original [MPL-2.0](docs/licenses/ZeroTierOne-MPL-2.0.txt); copyright ZeroTier, Inc.

### Acknowledgements

- [ZeroTier](https://github.com/zerotier/ZeroTier) — the network core
- Some animal icons are from [Material Design Icons](https://pictogrammers.com/) (Pictogrammers Free License) and [Font Awesome Free](https://fontawesome.com/) (CC BY 4.0; Icons by Font Awesome).

## Donate

If Planet Port helps you, consider buying the author a coffee ☕

<!-- TODO: replace with real QR code images (under docs/donate/) -->
| Alipay | WeChat |
|:---:|:---:|
| ![Alipay](docs/donate/alipay.png) | ![WeChat](docs/donate/wechat.png) |

- **BTC**: `TODO_address`
- **ETH**: `TODO_address`
- **afdian.com**: [TODO_profile_link](https://afdian.com)

## Known Limitations

- Existing ZeroTier identities cannot be imported (new nodes must be re-authorized in ZeroTier Central)
- The cellular hint is a fixed placeholder (current link type is not detected in real time)
- Not on the App Store; build and install from source
