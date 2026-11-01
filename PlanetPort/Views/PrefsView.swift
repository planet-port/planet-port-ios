import SwiftUI
import PhotosUI

/// 全局设置。Planet 的管理在首页卡片与其设置页中完成。
struct PrefsView: View {
    @EnvironmentObject private var app: AppState
    @AppStorage(AppGroup.prefDisableIPv6, store: AppGroup.defaults) private var disableIPv6 = false
    @AppStorage(AppGroup.prefMultiConnectLimit, store: AppGroup.defaults) private var multiConnectLimit = 2
    @AppStorage(AppGroup.prefConnectOnDemand, store: AppGroup.defaults) private var connectOnDemand = false
    @AppStorage(AppGroup.prefParallaxEnabled, store: AppGroup.defaults) private var parallaxEnabled = true
    @State private var showDonate = false
    // 语言切换刷新标题/文案（loc()），主题变更刷新主色圆点。
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var language = LanguageManager.shared
    @State private var showBackgroundPicker = false
    @State private var showThemePicker = false
    @State private var showIdentityMode = false
    /// 构建信息行当前显示 hash（false 显示时间）
    @State private var buildInfoShowsHash = false

    var body: some View {
        Form {
            Section {
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
                Toggle("prefs.ondemand", isOn: Binding(
                    get: { connectOnDemand },
                    set: { on in
                        connectOnDemand = on
                        VPNManager.shared.updateOnDemand()
                    }))
            } footer: {
                Text("prefs.ondemand.footer")
            }

            Section {
                Button {
                    showIdentityMode = true
                } label: {
                    HStack {
                        Text("prefs.identity.mode")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(app.identityPerPlanet ? "prefs.identity.mode.perPlanet"
                                                    : "prefs.identity.mode.shared")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("prefs.identity.sectionHeader")
            } footer: {
                Text("prefs.identity.footer")
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
                // 主题色入口（组内首位）：预设色板与自定义主色收进弹窗，外观区只留一行。
                Button {
                    showThemePicker = true
                } label: {
                    HStack {
                        Text("prefs.theme.sectionHeader")
                            .foregroundStyle(.primary)
                        Spacer()
                        Circle()
                            .fill(ThemeManager.color(hex: ThemeManager.shared.mainHex))
                            .frame(width: 24, height: 24)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                Button {
                    showBackgroundPicker = true
                } label: {
                    HStack {
                        Text("prefs.appearance.background")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let image = app.backgroundImage {
                            // 28pt 缩略图：与 Form 默认行高一致，不撑开选项高度。
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

            Section("prefs.about.sectionHeader") {
                aboutRow(loc("prefs.about.version"), Self.appVersion)
                // 构建时间 + git tag/短hash（preBuildScripts 生成）：用于确认手机上装的版本
                buildInfoRow
                aboutRow("ZeroTier Core", app.coreVersion.isEmpty ? loc("common.unknown") : app.coreVersion)
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
        .sheet(isPresented: $showThemePicker) {
            ThemeColorPickerSheet()
        }
        .sheet(isPresented: $showIdentityMode) {
            IdentityModeSheet()
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

    /// 构建信息行：默认显示构建时间，点击切换为 git hash（dirty 标记未提交改动）。
    /// 点击用手势而非 Button：Button label 会被全局 tint 染色。
    private var buildInfoRow: some View {
        HStack {
            Text(loc("prefs.about.buildTime"))
            Spacer()
            Text(buildInfoShowsHash ? Self.buildHashText : BuildInfo.time)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { buildInfoShowsHash.toggle() }
        }
    }

    private static var buildHashText: String {
        BuildInfo.hash + (BuildInfo.dirty ? " [dirty]" : "")
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

/// 主题色选择弹窗：示例色块（随机小动物叠加）+ 预置色板（同组无标题）→ 色盘 → 状态色派生开关。
private struct ThemeColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 叠加在示例色块上的随机小动物（与行星图标同一套 animal-<key> 资源），
    /// 每次打开弹窗随机换一只。
    @State private var animalKey = PlanetIcon.catalog[0]
    /// 示例色块/色板选中环/派生开关随取色即时变化。
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // 示例色块：当前主色大样，居中，上面叠一只随机小动物；
                    // 色块颜色随取色/预置选择即时变化。
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(ThemeManager.color(hex: ThemeManager.shared.mainHex))
                        Image("animal-\(animalKey)")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                    }
                    .frame(width: 120, height: 120)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    // 预置色板：单行 8 圆点，当前主色描环标识。
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
                }
                Section {
                    // 色盘：自绘 HSL 取色器（饱和度×亮度平面 + 色相条），
                    // 三值一个控件。不用系统 ColorPicker——它必然再弹一层
                    // 系统面板，且"最近颜色"无法隐藏。
                    HSLColorPicker()
                } header: {
                    Text("prefs.theme.wheel")
                }
                Section {
                    Toggle("prefs.theme.deriveStatus", isOn: Binding(
                        get: { ThemeManager.shared.deriveStatusColor },
                        set: { ThemeManager.shared.setDeriveStatusColor($0) }))
                } footer: {
                    Text("prefs.theme.footer")
                }
            }
            // 标题用 String 而非 key：loc() 建立语言观察，切换即时刷新。
            .navigationTitle(loc("prefs.theme.sectionHeader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .onAppear {
                animalKey = PlanetIcon.catalog.randomElement() ?? PlanetIcon.catalog[0]
            }
        }
    }
}

/// 自绘 HSL 取色器：饱和度（横向）× 亮度（纵向）取色板 + 色相条，
/// 三个分量合在一个控件内，读写直接走 ThemeManager.mainHex 单一数据源
/// （预设与色盘自动互相同步）。
private struct HSLColorPicker: View {
    /// 游标位置随外部（预设色板）改色同步。
    @ObservedObject private var theme = ThemeManager.shared

    /// 色相条渐变（红→黄→绿→青→蓝→洋红→红）。
    private static let hueStops: [Color] =
        (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }

    var body: some View {
        let hsl = ThemeManager.hsl(ThemeManager.shared.mainHex)
        VStack(spacing: 14) {
            satLightField(hsl)
            hueBar(hsl)
        }
    }

    private func apply(_ h: Double, _ s: Double, _ l: Double) {
        ThemeManager.shared.setMainColor(
            ThemeManager.hex(of: ThemeManager.color(ThemeManager.HSL(h: h, s: s, l: l))))
    }

    /// 饱和度×亮度平面：横向 白→纯色（s: 0→1），纵向 白→透明→黑（l: 1→0.5→0）。
    private func satLightField(_ hsl: ThemeManager.HSL) -> some View {
        let hueColor = ThemeManager.color(ThemeManager.HSL(h: hsl.h, s: 1, l: 0.5))
        return GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            ZStack {
                LinearGradient(colors: [.white, hueColor],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white, .clear, .black],
                               startPoint: .top, endPoint: .bottom)
                cursorCircle(at: CGPoint(x: w * hsl.s, y: h * (1 - hsl.l)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                apply(hsl.h,
                      min(max(g.location.x / w, 0), 1),
                      1 - min(max(g.location.y / h, 0), 1))
            })
        }
        .frame(height: 180)
    }

    /// 色相条：彩虹轨道 + 可拖圆钮。
    private func hueBar(_ hsl: ThemeManager.HSL) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: Self.hueStops,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                cursorCircle(at: CGPoint(x: w * hsl.h / 360, y: geo.size.height / 2))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                apply(min(max(g.location.x / w, 0), 1) * 360, hsl.s, hsl.l)
            })
        }
        .frame(height: 28)
    }

    /// 取色板/色相条上的游标：白心描边圆。
    private func cursorCircle(at point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 22, height: 22)
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
            .position(point)
    }
}

/// 身份模式选择页：共享 / 每行星独立 两行，点当前模式无动作；切独立先
/// alert 确认（其余行星将生成新身份、网络需重新授权），切共享进入身份
/// 选择页（无候选行星时直接切换，保持现共享身份）。
private struct IdentityModeSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPerPlanet = false
    @State private var showPick = false

    /// 已生成独立身份的行星（切共享时的候选；地址取自 identity.public）。
    private var candidates: [PlanetProfile] {
        app.planets.filter { IdentityStore.hasPlanetIdentity($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    modeRow(titleKey: "prefs.identity.mode.shared", isCurrent: !app.identityPerPlanet) {
                        if candidates.isEmpty {
                            app.switchIdentityMode(to: false, adopting: nil)
                            dismiss()
                        } else {
                            showPick = true
                        }
                    }
                    modeRow(titleKey: "prefs.identity.mode.perPlanet", isCurrent: app.identityPerPlanet) {
                        confirmPerPlanet = true
                    }
                } footer: {
                    Text("prefs.identity.footer")
                }
            }
            .navigationTitle(loc("prefs.identity.sectionHeader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
            .alert("prefs.identity.perPlanet.confirmTitle", isPresented: $confirmPerPlanet) {
                Button("prefs.identity.perPlanet.confirmAction") {
                    app.switchIdentityMode(to: true, adopting: nil)
                    dismiss()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("prefs.identity.perPlanet.confirmMessage")
            }
            .navigationDestination(isPresented: $showPick) {
                IdentityPickView(candidates: candidates) { planetId in
                    app.switchIdentityMode(to: false, adopting: planetId)
                    dismiss()
                }
            }
        }
    }

    /// 模式行：当前模式纯展示（checkmark），其它模式可点触发 action。
    private func modeRow(titleKey: LocalizedStringKey, isCurrent: Bool,
                         action: @escaping () -> Void) -> some View {
        HStack {
            Text(titleKey)
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isCurrent { action() } }
        .foregroundStyle(.primary)
    }
}

/// 共享身份选择页：列出已生成独立身份的行星，点选其身份成为全局共享身份。
private struct IdentityPickView: View {
    let candidates: [PlanetProfile]
    let onPick: (String) -> Void

    var body: some View {
        Form {
            Section {
                if candidates.isEmpty {
                    Text("prefs.identity.pick.empty")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { planet in
                    Button {
                        onPick(planet.id)
                    } label: {
                        HStack {
                            Image(PlanetIcon.assetName(for: planet))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .frame(width: 24, height: 24)
                                .background(PlanetIcon.tint(for: planet),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            Text(planet.displayName)
                            Spacer()
                            Text(IdentityStore.planetIdentityAddress(planet.id) ?? "—")
                                .foregroundStyle(.secondary)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("prefs.identity.pick.footer")
            }
        }
        .navigationTitle(loc("prefs.identity.pick.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
