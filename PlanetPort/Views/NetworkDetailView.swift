import SwiftUI

/// 网络详情（对齐 Android NetworkDetailFragment：静态+实时配置合并展示）
struct NetworkDetailView: View {
    @EnvironmentObject var app: AppState
    let entry: NetworkEntry

    @State private var snapshot: NetworkConfigSnapshot?
    @State private var showDelete = false
    @State private var dns = DNSConfig()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row("网络 ID", entry.networkId)
                row("名称", snapshot?.name ?? entry.networkName)
                row("状态", snapshot.map { $0.status } ?? "—")
                row("类型", snapshot?.type ?? "—")
                row("MAC", snapshot?.mac ?? "—")
                row("MTU", snapshot.map { String($0.mtu) } ?? "—")
                row("广播", snapshot.map { $0.broadcastEnabled ? "允许" : "禁止" } ?? "—")
                row("桥接", snapshot.map { $0.bridge ? "是" : "否" } ?? "—")
            }
            Section("分配的地址") {
                if let addrs = snapshot?.assignedAddrs, !addrs.isEmpty {
                    ForEach(addrs, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                } else { Text("—") }
            }
            Section("托管路由") {
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
                        Text("等待网络下发…").foregroundStyle(.secondary)
                    }
                }
                // 改 DNS 会触发热重配隧道（重建网络设置），用显式"应用"确认，不做静默生效。
                if dnsDirty {
                    Button("应用 DNS 配置") { applyDNS() }
                        .disabled(!dns.isValid)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } header: {
                Text("DNS")
            } footer: {
                Text("修改后需点「应用」生效；隧道运行时会自动重配，无需断开重连。")
            }
            Section {
                Toggle("经 ZeroTier 路由（默认路由）", isOn: Binding(
                    get: { currentEntry.routeViaZeroTier },
                    set: updateRouteViaZeroTier))
            } footer: {
                Text("开启后该网络的默认路由经 ZeroTier，立即生效")
            }
            Section {
                Button(role: .destructive) { showDelete = true } label: {
                    Text("删除网络")
                }
            }
        }
        .navigationTitle("网络详情")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refresh()
            dns = DNSConfig(mode: currentEntry.dnsMode, customDns: currentEntry.customDns)
        }
        .refreshable { refresh() }
        .confirmationDialog("删除这个网络？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除网络", role: .destructive) { deleteNetwork() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从当前行星的网络列表中移除；若隧道正在使用，将停止加入该网络。")
        }
    }

    private var currentEntry: NetworkEntry {
        app.networks.first { $0.networkId == entry.networkId } ?? entry
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

    /// 对齐 Android updateTunnelConfig 的热重配路径：写配置文件 + Darwin 通知隧道重读。
    private func applyDNS() {
        var networks = app.networks
        guard let idx = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[idx].dnsMode = dns.mode
        networks[idx].customDns = dns.mode == .custom ? dns.customServers : []
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
    }

    /// 对齐 Android NetworkDetailModel.doUpdateRouteViaZeroTier：写库 + 通知隧道重配
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
