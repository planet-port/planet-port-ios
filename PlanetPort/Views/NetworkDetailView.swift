import SwiftUI

/// 网络详情（静态+实时配置合并展示）
struct NetworkDetailView: View {
    @EnvironmentObject var app: AppState
    let entry: NetworkEntry

    @State private var snapshot: NetworkConfigSnapshot?
    @State private var showQR = false
    /// 已切到 via 网关视图的路由下标（点击行首标签外的值区域切换）
    @State private var viaExpandedRoutes: Set<Int> = []
    @State private var showDelete = false
    @State private var dns = DNSConfig()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                networkIdRow
                row(loc("common.name"), snapshot?.name ?? entry.networkName)
                // REQUESTING_CONFIGURATION 与卡片一致按 online 分段（连接服务器/请求网络配置/连接超时）；
                // 物理断网（飞行模式）与卡片一致显示"无网络"（同样以隧道在跑为前提）
                row(loc("common.status"), snapshot.map {
                    app.vpnRunning && !app.pathSatisfied
                        ? loc("status.noNetwork")
                        : $0.status == .requestingConfiguration
                            ? NetworkCardStatus.connectPhaseText(app: app)
                            : $0.status.displayName
                } ?? "—")
                row(loc("common.type"), snapshot?.type ?? "—")
                CopyableRow(title: "MAC", text: macText)
                row("MTU", snapshot.map { String($0.mtu) } ?? "—")
                row(loc("network.broadcast"),
                    snapshot.map { $0.broadcastEnabled ? loc("common.allowed")
                                                       : loc("common.forbidden") } ?? "—")
                row(loc("network.bridge"),
                    snapshot.map { $0.bridge ? loc("common.yes")
                                             : loc("common.no") } ?? "—")
            }
            Section("network.assignedAddrs") {
                if let addrs = snapshot?.assignedAddrs, !addrs.isEmpty {
                    ForEach(Array(addrs.enumerated()), id: \.element) { index, addr in
                        HStack {
                            Text(loc("network.addrLabel \(index + 1)"))
                            Spacer()
                            CopyableValue(text: addr)
                        }
                    }
                } else { row(loc("network.addr"), "—") }
            }
            Section("network.managedRoutes") {
                if let routes = snapshot?.routes, !routes.isEmpty {
                    // id 用 offset：路由字符串可能重复，且展开状态按下标追踪
                    ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                        RouteRow(
                            index: index,
                            route: route,
                            viaExpanded: viaExpandedRoutes.contains(index)
                        ) {
                            if viaExpandedRoutes.contains(index) {
                                viaExpandedRoutes.remove(index)
                            } else {
                                viaExpandedRoutes.insert(index)
                            }
                        }
                    }
                } else { row(loc("network.route"), "—") }
            }
            Section {
                DNSConfigSection(config: $dns)
                // 网络模式下 ZT 下发的服务器只读展示，与自定义输入区分。
                if dns.mode == .network {
                    if let servers = snapshot?.dns, !servers.isEmpty {
                        ForEach(servers, id: \.self) {
                            Text($0).font(.system(.body, design: .monospaced))
                        }
                    } else {
                        Text("network.dnsPending").foregroundStyle(.secondary)
                    }
                }
                // 改 DNS 会触发热重配隧道（重建网络设置），用显式"应用"确认，不做静默生效。
                if dnsDirty {
                    Button("network.applyDns") { applyDNS() }
                        .disabled(!dns.isValid)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text("DNS")
            } footer: {
                Text("network.dnsFooter")
            }
            Section {
                Toggle("network.routeVia", isOn: Binding(
                    get: { currentEntry.routeViaZeroTier },
                    set: updateRouteViaZeroTier))
                    .disabled(routeViaLocked)
            } footer: {
                if routeViaLocked {
                    Text("network.routeVia.lockedFooter")
                } else {
                    Text("network.routeVia.footer")
                }
            }
            Section {
                Button(role: .destructive) { showDelete = true } label: {
                    Text("network.delete")
                        // iOS 26 List 内 Section 按钮默认渲染为居中，此处按系统设置页惯例左对齐
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("network.detailTitle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
            dns = DNSConfig(mode: currentEntry.dnsMode, customDns: currentEntry.customDns)
        }
        .refreshable { refresh() }
        .sheet(isPresented: $showQR) { NetworkQRSheet(entry: currentEntry, snapshot: snapshot) }
        .confirmationDialog("network.delete.confirmTitle", isPresented: $showDelete, titleVisibility: .visible) {
            Button("network.delete", role: .destructive) { deleteNetwork() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("network.delete.confirmMessage")
        }
    }

    /// 详情页数据的查找锚定网络归属的行星（entry.planetId），不依赖全局选中页。
    private var currentEntry: NetworkEntry {
        let list = entry.planetId.flatMap { app.planetNetworks[$0] } ?? []
        return list.first { $0.networkId == entry.networkId } ?? entry
    }

    /// 网络 ID 行:点击复制(无常驻图标,仅二维码入口,避免双图标)。
    private var networkIdRow: some View {
        HStack {
            Text(loc("network.id"))
            Spacer()
            CopyableValue(text: entry.networkId, showsIcon: false)
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

    /// 多网络同时连接时默认路由的唯一性无解，锁定开关（控制面与数据面双侧拦截）。
    /// 判断锚定本网络所属行星：只有隧道行星下才存在"同时连接"的其他网络。
    private var routeViaLocked: Bool {
        guard entry.planetId == app.activePlanetId else { return false }
        let list = entry.planetId.flatMap { app.planetNetworks[$0] } ?? []
        return list.contains { $0.networkId != entry.networkId && $0.lastActivated }
    }

    /// 编辑中的 DNS 与已保存配置是否存在差异（决定"应用"按钮是否出现）。
    private var dnsDirty: Bool {
        dns.mode != currentEntry.dnsMode
            || dns.customServers != currentEntry.customDns
    }

    private func refresh() {
        // 实时快照只对隧道行星的网络有意义；不同行星可能加入同 ID 的网络，
        // 非隧道行星不查询，避免拿到隧道行星同名网络的配置（数据串台）。
        guard entry.planetId == app.activePlanetId else {
            snapshot = nil
            return
        }
        VPNManager.shared.query(ProviderRequest(type: "networkConfig", nwid: entry.networkId)) { reply in
            Task { @MainActor in
                snapshot = reply?.networkConfig
            }
        }
    }

    /// 热重配路径：写配置文件 + Darwin 通知隧道重读。写回网络归属的行星。
    private func applyDNS() {
        let planetId = entry.planetId ?? app.selectedPlanetId
        var networks = AppConfigStore.readNetworks(planetId: planetId)
        guard let idx = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[idx].dnsMode = dns.mode
        networks[idx].customDns = dns.mode == .custom ? dns.customServers : []
        AppConfigStore.writeNetworks(networks, planetId: planetId)
        app.reloadConfig()
    }

    /// 写库 + 通知隧道重配。写回网络归属的行星。
    private func updateRouteViaZeroTier(_ on: Bool) {
        let planetId = entry.planetId ?? app.selectedPlanetId
        var networks = AppConfigStore.readNetworks(planetId: planetId)
        guard let idx = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[idx].routeViaZeroTier = on
        AppConfigStore.writeNetworks(networks, planetId: planetId)
        app.reloadConfig()
    }

    private func deleteNetwork() {
        let planetId = entry.planetId ?? app.selectedPlanetId
        var networks = AppConfigStore.readNetworks(planetId: planetId)
        networks.removeAll { $0.networkId == entry.networkId }
        AppConfigStore.writeNetworks(networks, planetId: planetId)
        app.reloadConfig()
        // 删掉的是最后一个启用的网络时，VPN 随之关闭，不空跑。
        app.stopVPNIfNoActiveNetworks()
        dismiss()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

/// 路由行：路由串较长（`目标 via 网关`），默认只显示目标网段，
/// 点击值区域切换为 via 网关；直连路由（无 via）不可切换、不显示图标。
private struct RouteRow: View {
    let index: Int
    let route: String
    let viaExpanded: Bool
    let toggle: () -> Void

    /// "192.168.8.0/24 via 152.124.13.2" → "192.168.8.0/24"
    private var target: String {
        route.components(separatedBy: " via ").first ?? route
    }

    /// via 网关；nil = 直连路由
    private var via: String? {
        let parts = route.components(separatedBy: " via ")
        return parts.count > 1 ? parts[1] : nil
    }

    var body: some View {
        HStack {
            Text(loc("network.routeLabel \(index + 1)"))
            Spacer()
            if let via {
                // 不用 Button：Button label 会被全局 tint 染成主色，这里值要跟其他行一致（.secondary）。
                // 与 CopyableValue 相同方案：contentShape + onTapGesture 承接点击。
                HStack(spacing: 4) {
                    Text(viaExpanded ? "via \(via)" : target)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .accessibilityLabel(Text("network.managedRoutes"))
                .accessibilityValue(Text(route))
            } else {
                Text(target)
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

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
