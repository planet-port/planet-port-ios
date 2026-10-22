import SwiftUI

/// 加入网络（对齐 Android JoinNetworkFragment）
struct JoinNetworkSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var networkId = ""
    @State private var routeViaZeroTier = false
    @State private var dns = DNSConfig()
    @State private var showScanner = false
    @State private var duplicateAlert = false

    private var idValid: Bool {
        networkId.count == 16 && networkId.allSatisfy { $0.isHexDigit }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("网络 ID") {
                    HStack {
                        TextField("16 位十六进制", text: $networkId)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                        // 输入框尾部扫码按钮：识别二维码中的网络 ID 填入。
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode")
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("扫码识别网络 ID")
                    }
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
            .alert("网络已存在", isPresented: $duplicateAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text("网络 \(networkId.lowercased()) 已在列表中，不能重复添加。")
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { id in
                    // 回填 ID 并停留在加入弹窗，只关闭扫码层。
                    networkId = id
                    showScanner = false
                }
            }
        }
    }

    private func join() {
        // 网络 ID 查重：已存在视为同一网络，禁止重复添加。
        let newId = networkId.lowercased()
        guard !app.networks.contains(where: { $0.networkId == newId }) else {
            duplicateAlert = true
            return
        }
        let entry = NetworkEntry(networkId: newId,
                                 networkName: newId,
                                 // 仅保存不自动连接，由用户手动打开开关。
                                 lastActivated: false,
                                 routeViaZeroTier: routeViaZeroTier,
                                 dnsMode: dns.mode,
                                 customDns: dns.mode == .custom ? dns.customServers : [])
        var networks = app.networks
        networks.append(entry)
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
        // 添加完不自动连接，需要时由用户在网络卡片上手动打开开关。
        // app.applySelectedPlanetAndStartVPN { _, _ in }
        dismiss()
    }
}
