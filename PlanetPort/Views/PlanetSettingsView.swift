import SwiftUI

/// Planet 设置页：名称、图标、只读信息、Peers/Moon 入口与删除。
/// 官方 Planet 名称/图标只读且不可删除。
struct PlanetSettingsView: View {
    let planetId: String

    @EnvironmentObject private var app: AppState
    // 图标底色与时间戳格式化随主题/语言即时刷新。
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var showIconPicker = false
    @State private var qrShareSession: QRShareSession?
    @State private var showFileShare = false
    @State private var showDelete = false
    @State private var alert: String?

    private var planet: PlanetProfile? {
        app.planets.first { $0.id == planetId }
    }

    private var isOfficial: Bool {
        planet?.kind == .official
    }

    var body: some View {
        Form {
            nameAndIconSection
            infoSection
            diagnosticsSection
            if !isOfficial {
                Section {
                    Button(role: .destructive) { showDelete = true } label: {
                        Text("planet.delete")
                            .frame(maxWidth: .infinity)
                    }
                    // borderless：默认样式在 Form 内接管行布局，外部/内部对齐修饰全部失效；
                    // borderless 尊重 label 的 frame，destructive 红色保持
                    .buttonStyle(.borderless)
                    // 弹窗挂按钮本身：挂 Form 层时锚点偏离按钮，弹出位置跑偏
                    .confirmationDialog("planet.delete.confirmTitle",
                                        isPresented: $showDelete,
                                        titleVisibility: .visible) {
                        Button("planet.delete.confirmAction", role: .destructive) { deletePlanet() }
                        Button("common.cancel", role: .cancel) {}
                    } message: {
                        Text("common.irreversible")
                    }
                } footer: {
                    Text("planet.delete.footer")
                }
            }
        }
        .navigationTitle(planet?.displayName ?? loc("planet.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = planet?.name ?? "" }
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(animal: PlanetIcon.animalKey(for: planet ?? .official),
                            color: PlanetIcon.effectiveColorHex(for: planet)) { animal, color in
                do {
                    try PlanetImporter.updateIcon(planet ?? .official, icon: animal, color: color)
                    app.reloadConfig()
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
        // sheet(item:)：内容闭包直接收非可选会话。此前用 isPresented+if let，
        // 首次呈现事务里闭包读到旧值 nil → 空 sheet 且无重求值火花，空白悬置
        // 数秒（仅冷启动首次分享可复现）。
        .sheet(item: $qrShareSession) { session in
            QRShareView(title: loc("planet.share.qr.title"), session: session)
        }
        .sheet(isPresented: $showFileShare) {
            if let url = planetFileURL {
                ActivityShareSheet(items: [url])
                    .ignoresSafeArea()
            }
        }
        .alert(loc("common.notice"), isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
    }

    // MARK: - 名称与图标

    private var nameAndIconSection: some View {
        Section {
            HStack {
                Text("common.name")
                Spacer()
                if isOfficial {
                    Text(planet?.displayName ?? "")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("common.name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                        .onChange(of: nameFocused) { focused in
                            if !focused { saveName() }
                        }
                }
            }
            Button {
                showIconPicker = true
            } label: {
                HStack {
                    Text("common.icon")
                    Spacer()
                    if let planet {
                        Image(PlanetIcon.assetName(for: planet))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                            .frame(width: 24, height: 24)
                            .background(PlanetIcon.tint(for: planet),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    if !isOfficial {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }
            }
            // plain 样式:Form 按钮默认把整个标签染成主色,脱离后文字用默认色
            .buttonStyle(.plain)
            .disabled(isOfficial)
        } footer: {
            if isOfficial {
                Text("planet.info.officialOnly")
            }
        }
    }

    // MARK: - 只读信息

    private var infoSection: some View {
        Section {
            row("World ID", app.planetWorldIds[planetId] ?? "—")
            CopyableRow(title: loc("planet.info.nodeId"), text: nodeIDText)
            if let planet {
                row(loc("common.type"),
                    isOfficial ? loc("planet.info.officialKind")
                               : loc("planet.info.customKind"))
                // "文件"项无意义，隐藏。
                // if let fileName = planet.fileName {
                //     row("文件", fileName)
                // }
                if let info = PlanetImporter.inspectPlanetFile(planet) {
                    fileSizeRow(info)
                    row(loc("planet.info.revision"), Self.timestampText(info.timestamp))
                }
                if !isOfficial, planetFileURL != nil {
                    HStack {
                        Text("common.share")
                        Spacer()
                        Button {
                            showFileShare = true
                        } label: {
                            shareLabel("planet.share.file", icon: "doc")
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .frame(height: 14)
                        Button {
                            shareQR()
                        } label: {
                            shareLabel("planet.share.qr", icon: "qrcode")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } footer: {
            Text("planet.info.footer")
        }
    }

    private var nodeIDText: String {
        // 当前激活行星优先显示实时值，其余/离线回退到缓存。
        if planetId == app.activePlanetId, !app.nodeId.isEmpty { return app.nodeId }
        return app.planetNodeIds[planetId] ?? "—"
    }

    /// 文件大小行。分享入口已独立成"分享"行（文件/二维码两个选项）。
    private func fileSizeRow(_ info: (worldId: UInt64, timestamp: UInt64, fileSize: Int)) -> some View {
        HStack {
            Text(loc("planet.info.fileSize"))
            Spacer()
            Text(locFileSize(info.fileSize))
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var planetFileURL: URL? {
        guard let fileName = planet?.fileName else { return nil }
        let url = AppGroup.planetsDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func timestampText(_ ts: UInt64) -> String {
        guard ts > 0 else { return "—" }
        // ZeroTier World 时间戳为毫秒。
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        // 格式化器不走 SwiftUI locale 环境，显式带应用语言（单位/日期与文案一致）。
        return date.formatted(
            Date.FormatStyle(date: .numeric, time: .shortened)
                .locale(LanguageManager.shared.locale))
    }

    // MARK: - 诊断入口

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                PeerListView()
            } label: {
                Label("planet.diagnostics.peers", systemImage: "person.2")
            }
            .disabled(planetId != app.activePlanetId)
            NavigationLink {
                MoonView()
            } label: {
                Label("planet.diagnostics.moons", systemImage: "moon.stars")
            }
            NavigationLink {
                ApplyTraceView()
            } label: {
                Label("planet.diagnostics.trace", systemImage: "waveform.path.ecg")
            }
        } footer: {
            Text("planet.diagnostics.footer")
        }
    }

    // MARK: - 操作

    /// 分享选项按钮:图标 11pt(与节点 ID 行复制图标同尺寸)、
    /// 图标文字间距 4pt、颜色跟随正文标签(.primary)。
    private func shareLabel(_ key: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(key)
        }
        .foregroundStyle(.primary)
    }

    /// 读取 planet 文件进入二维码分享；读取失败(并发删除)不弹页。
    /// 会话在此创建即开始编码渲染，与 sheet 呈现动画并行，
    /// 避免 sheet 内容 .task 等动画播完才触发导致首帧迟滞。
    private func shareQR() {
        guard let url = planetFileURL, let data = try? Data(contentsOf: url) else { return }
        qrShareSession = QRShareSession(
            data: data, side: UIScreen.main.bounds.width * 0.72)
    }

    private func saveName() {
        guard let planet, name != planet.name else { return }
        do {
            try PlanetImporter.rename(planet, to: name)
            app.reloadConfig()
        } catch {
            alert = error.localizedDescription
        }
    }

    /// 删除顺序：激活中先停 VPN，级联清理由 AppConfigStore.deletePlanet 完成。
    private func deletePlanet() {
        guard let planet else { return }
        if planet.id == app.activePlanetId {
            VPNManager.shared.stop()
        }
        AppConfigStore.deletePlanet(planet)
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 系统分享面板（UIActivityViewController）的 SwiftUI 封装。
/// 行内按钮无法原地触发 ShareLink，改由 sheet 承载。
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
