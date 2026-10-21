import SwiftUI

/// 加入网络（对齐 Android JoinNetworkFragment）
struct JoinNetworkSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var networkId = ""
    @State private var routeViaZeroTier = false
    @State private var dns = DNSConfig()

    private var idValid: Bool {
        networkId.count == 16 && networkId.allSatisfy { $0.isHexDigit }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("网络 ID") {
                    TextField("16 位十六进制", text: $networkId)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    if !networkId.isEmpty && !idValid {
                        Text("网络 ID 必须为 16 位十六进制字符")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("默认路由经 ZeroTier", isOn: $routeViaZeroTier)
                } footer: {
                    Text("开启后所有流量经 ZeroTier 隧道路由")
                }
                Section("DNS") {
                    DNSConfigSection(config: $dns)
                }
            }
            .navigationTitle("加入网络")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入") { join() }
                        .disabled(!idValid || !dns.isValid)
                }
            }
        }
    }

    private func join() {
        let entry = NetworkEntry(networkId: networkId.lowercased(),
                                 networkName: networkId.lowercased(),
                                 // 仅保存不自动连接，由用户手动打开开关。
                                 lastActivated: false,
                                 routeViaZeroTier: routeViaZeroTier,
                                 dnsMode: dns.mode,
                                 customDns: dns.mode == .custom ? dns.customServers : [])
        var networks = app.networks
        networks.removeAll { $0.networkId == entry.networkId }  // 重复添加 = 覆盖
        networks.append(entry)
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
        // 添加完不自动连接，需要时由用户在网络卡片上手动打开开关。
        // app.applySelectedPlanetAndStartVPN { _, _ in }
        dismiss()
    }
}
