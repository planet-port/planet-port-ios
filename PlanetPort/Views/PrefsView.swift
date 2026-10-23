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
                Toggle("prefs.network.allowCellular", isOn: $allowCellular)
                Toggle("prefs.network.disableIPv6", isOn: Binding(
                    get: { disableIPv6 },
                    set: { on in
                        disableIPv6 = on
                        VPNManager.shared.restartIfRunning()
                    }))
                Stepper("prefs.network.multiConnectLimit \(multiConnectLimit)", value: $multiConnectLimit, in: 2...6)
            } header: {
                Text("prefs.network.sectionHeader")
            } footer: {
                Text("prefs.network.footer")
            }

            Section {
                // 语言选项：各语言以自身名称显示，仅"跟随系统"随界面语言本地化。
                Picker("prefs.language.sectionHeader", selection: languageBinding) {
                    // "跟随系统"始终以系统语言显示：绕过 locale 环境，直接按
                    // 系统首选语言查表（String 构造不读 environment(\.locale)）。
                    Text(String(localized: "prefs.language.system")).tag(AppLanguage.system)
                    ForEach(AppLanguage.allCases.filter { $0.nativeName != nil }) { lang in
                        Text(lang.nativeName!).tag(lang)
                    }
                }
            }
            Section {
                Button {
                    showBackgroundPicker = true
                } label: {
                    HStack {
                        Text("prefs.appearance.background")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let image = app.backgroundImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text("common.notSet")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                // plain 样式：Form 按钮默认把整个标签染成主色，脱离后文字用默认色
                .buttonStyle(.plain)
                Toggle("prefs.appearance.parallax", isOn: $parallaxEnabled)
                    .disabled(app.backgroundImage == nil)
                    // 禁用时标签同步置灰，避免被误读为可用状态
                    .foregroundStyle(app.backgroundImage == nil ? Color.secondary : Color.primary)            } header: {
                Text("prefs.appearance.sectionHeader")
            } footer: {
                Text("prefs.appearance.footer")
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
                        .accessibilityLabel(loc("prefs.theme.a11yPreset \(ThemeManager.presetNames[index])"))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                ColorPicker("prefs.theme.custom", selection: Binding(
                    get: { ThemeManager.color(hex: ThemeManager.shared.mainHex) },
                    set: { ThemeManager.shared.setMainColor(ThemeManager.hex(of: $0)) }))
                Toggle("prefs.theme.deriveStatus", isOn: Binding(
                    get: { ThemeManager.shared.deriveStatusColor },
                    set: { ThemeManager.shared.setDeriveStatusColor($0) }))
            } header: {
                Text("prefs.theme.sectionHeader")
            } footer: {
                Text("prefs.theme.footer")
            }

            Section {
                Toggle("prefs.ondemand", isOn: Binding(
                    get: { connectOnDemand },
                    set: { on in
                        connectOnDemand = on
                        VPNManager.shared.updateOnDemand()
                    }))
            } footer: {
                Text("prefs.ondemand.footer")
            }

            Section("prefs.about.sectionHeader") {
                aboutRow("ZeroTier Core", app.coreVersion.isEmpty ? loc("common.unknown") : app.coreVersion)
                aboutRow(loc("prefs.about.version"), Self.appVersion)
            }

            // 支持区暂隐藏（内容待补充），代码保留。
            if false {
                Section("prefs.support.sectionHeader") {
                    Button {
                        showDonate = true
                    } label: {
                        HStack {
                            Text("prefs.support.donate")
                            Spacer()
                            Image(systemName: "heart")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        // 标题用 String 而非 key：loc() 读取语言状态建立观察，切换即时刷新
        // （navigationTitle 的 key 查表不受 locale 环境驱动，会出现滞后）。
        .navigationTitle(loc("common.settings"))
        .navigationBarTitleDisplayMode(.inline)
        // 捐赠弹窗：内容暂空。
        .sheet(isPresented: $showDonate) {
            NavigationStack {
                Color.clear
                    .navigationTitle("prefs.support.donate")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showBackgroundPicker) {
            BackgroundImagePickerSheet()
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { LanguageManager.shared.current },
            set: { LanguageManager.shared.set($0) })
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
