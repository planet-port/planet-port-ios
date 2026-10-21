import SwiftUI

/// 全局设置。Planet 的管理在首页卡片与其设置页中完成。
struct PrefsView: View {
    @EnvironmentObject private var app: AppState
    @AppStorage(AppGroup.prefAllowCellular, store: AppGroup.defaults) private var allowCellular = false
    @AppStorage(AppGroup.prefDisableIPv6, store: AppGroup.defaults) private var disableIPv6 = false
    @AppStorage(AppGroup.prefConnectOnDemand, store: AppGroup.defaults) private var connectOnDemand = false
    @State private var showDonate = false

    var body: some View {
        Form {
            Section("网络") {
                Toggle("允许移动数据", isOn: $allowCellular)
                Toggle("禁用 IPv6", isOn: Binding(
                    get: { disableIPv6 },
                    set: { on in
                        disableIPv6 = on
                        VPNManager.shared.restartIfRunning()
                    }))
            }

            Section {
                Toggle("按需连接（Connect On Demand）", isOn: Binding(
                    get: { connectOnDemand },
                    set: { on in
                        connectOnDemand = on
                        VPNManager.shared.updateOnDemand()
                    }))
            } footer: {
                Text("开启后系统在网络可用时自动建立 VPN；实际使用哪个行星仍由网络开关决定。")
            }

            Section("支持") {
                Button {
                    showDonate = true
                } label: {
                    HStack {
                        Text("捐赠")
                        Spacer()
                        Image(systemName: "heart")
                            .foregroundStyle(.tint)
                    }
                }
            }

            Section("关于") {
                aboutRow("ZeroTier Core", app.coreVersion.isEmpty ? "未知" : app.coreVersion)
                aboutRow("版本", Self.appVersion)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        // 捐赠弹窗：内容暂空。
        .sheet(isPresented: $showDonate) {
            NavigationStack {
                Color.clear
                    .navigationTitle("捐赠")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
