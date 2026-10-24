import SwiftUI

/// 网络详情（静态+实时配置合并展示）
struct NetworkDetailView: View {
    @EnvironmentObject var app: AppState
    let entry: NetworkEntry

    @State private var snapshot: NetworkConfigSnapshot?
    @State private var showQR = false
    @State private var showDelete = false
    @State private var dns = DNSConfig()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                networkIdRow
                row(loc("common.name"), snapshot?.name ?? entry.networkName)
                row(loc("common.status"), snapshot.map { $0.status.displayName } ?? "—")
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
                    ForEach(addrs, id: \.self) { addr in
                        CopyableValue(text: addr)
                    }
                } else { Text("—") }
            }
            Section("network.managedRoutes") {
                if let routes = snapshot?.routes, !routes.isEmpty {
                    ForEach(routes, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                } else { Text("—") }
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

    private var currentEntry: NetworkEntry {
        app.networks.first { $0.networkId == entry.networkId } ?? entry
    }

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

    /// 多网络同时连接时默认路由的唯一性无解，锁定开关（控制面与数据面双侧拦截）。
    private var routeViaLocked: Bool {
        app.selectedPlanetId == app.activePlanetId
            && app.networks.contains { $0.networkId != entry.networkId && $0.lastActivated }
    }

    /// 编辑中的 DNS 与已保存配置是否存在差异（决定"应用"按钮是否出现）。
    private var dnsDirty: Bool {
        dns.mode != currentEntry.dnsMode
            || dns.customServers != currentEntry.customDns
    }

    private func refresh() {
        VPNManager.shared.query(ProviderRequest(type: "networkConfig", nwid: entry.networkId)) { reply in
            Task { @MainActor in
                snapshot = reply?.networkConfig
            }
        }
    }

    /// 热重配路径：写配置文件 + Darwin 通知隧道重读。
    private func applyDNS() {
        var networks = app.networks
        guard let idx = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[idx].dnsMode = dns.mode
        networks[idx].customDns = dns.mode == .custom ? dns.customServers : []
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
    }

    /// 写库 + 通知隧道重配
    private func updateRouteViaZeroTier(_ on: Bool) {
        var networks = app.networks
        guard let idx = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[idx].routeViaZeroTier = on
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
    }

    private func deleteNetwork() {
        var networks = app.networks
        networks.removeAll { $0.networkId == entry.networkId }
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
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
