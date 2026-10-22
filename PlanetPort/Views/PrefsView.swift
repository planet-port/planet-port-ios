import SwiftUI
import PhotosUI

/// 全局设置。Planet 的管理在首页卡片与其设置页中完成。
struct PrefsView: View {
    @EnvironmentObject private var app: AppState
    @AppStorage(AppGroup.prefAllowCellular, store: AppGroup.defaults) private var allowCellular = true
    @AppStorage(AppGroup.prefDisableIPv6, store: AppGroup.defaults) private var disableIPv6 = false
    @AppStorage(AppGroup.prefMultiConnectLimit, store: AppGroup.defaults) private var multiConnectLimit = 2
    @AppStorage(AppGroup.prefConnectOnDemand, store: AppGroup.defaults) private var connectOnDemand = false
    @AppStorage(AppGroup.prefParallaxEnabled, store: AppGroup.defaults) private var parallaxEnabled = true
    @State private var showDonate = false
    @State private var showBackgroundPicker = false

    var body: some View {
        Form {
            Section {
                Toggle("允许移动数据", isOn: $allowCellular)
                Toggle("禁用 IPv6", isOn: Binding(
                    get: { disableIPv6 },
                    set: { on in
                        disableIPv6 = on
                        VPNManager.shared.restartIfRunning()
                    }))
                Stepper("同时连接上限：\(multiConnectLimit)", value: $multiConnectLimit, in: 2...6)
            } header: {
                Text("网络")
            } footer: {
                Text("同时连接多个网络会增加耗电；超出上限时会提示确认，仍可强制开启。")
            }

            Section {
                Button {
                    showBackgroundPicker = true
                } label: {
                    HStack {
                        Text("背景图")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let image = app.backgroundImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text("未设置")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Toggle("视差动画", isOn: $parallaxEnabled)
                    .disabled(app.backgroundImage == nil)
            } header: {
                Text("外观")
            } footer: {
                Text("背景图可从相册选择或通过 URL 下载；视差动画仅在设置了背景图时生效。")
            }

            Section {
                // 预设色板：单行 8 圆点，当前主色描环标识。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8),
                          spacing: 4) {
                    ForEach(Array(ThemeManager.presets.enumerated()), id: \.offset) { index, hex in
                        Button {
                            ThemeManager.shared.setMainColor(hex)
                        } label: {
                            Circle()
                                .fill(ThemeManager.color(hex: hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    // 选中标记：白色描环。
                                    if hex == ThemeManager.shared.mainHex {
                                        Circle()
                                            .strokeBorder(Color.white, lineWidth: 2)
                                            .padding(2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("主色 \(ThemeManager.presetNames[index])")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                ColorPicker("自定义主色", selection: Binding(
                    get: { ThemeManager.color(hex: ThemeManager.shared.mainHex) },
                    set: { ThemeManager.shared.setMainColor(ThemeManager.hex(of: $0)) }))
                Toggle("状态色跟随主色派生", isOn: Binding(
                    get: { ThemeManager.shared.deriveStatusColor },
                    set: { ThemeManager.shared.setDeriveStatusColor($0) }))
            } header: {
                Text("主题色")
            } footer: {
                Text("主色决定按钮、指示器与行星装饰色，深浅模式自动适配；状态色默认保持绿/橙/红语义，打开开关后成功色随主色三角派生。")
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

            Section("关于") {
                aboutRow("ZeroTier Core", app.coreVersion.isEmpty ? "未知" : app.coreVersion)
                aboutRow("版本", Self.appVersion)
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
        .sheet(isPresented: $showBackgroundPicker) {
            BackgroundImagePickerSheet()
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
