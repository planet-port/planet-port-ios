import SwiftUI

/// Planet 设置页：名称、图标、只读信息、Peers/Moon 入口与删除。
/// 官方 Planet 名称/图标只读且不可删除。
struct PlanetSettingsView: View {
    let planetId: String

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var showIconPicker = false
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
                        Text("删除此行星")
                    }
                } footer: {
                    Text("将一并删除该行星下保存的网络和卫星。若隧道正在使用它，VPN 将停止并回退到官方行星。")
                }
            }
        }
        .navigationTitle(planet?.name ?? "行星")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = planet?.name ?? "" }
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(current: planet?.icon ?? "") { symbol in
                do {
                    try PlanetImporter.updateIcon(planet ?? .official, to: symbol)
                    app.reloadConfig()
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
        .confirmationDialog("删除这颗行星？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除行星、网络和卫星", role: .destructive) { deletePlanet() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销。")
        }
        .alert("提示", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
    }

    // MARK: - 名称与图标

    private var nameAndIconSection: some View {
        Section {
            HStack {
                Text("名称")
                Spacer()
                if isOfficial {
                    Text(planet?.name ?? "")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("名称", text: $name)
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
                    Text("图标")
                    Spacer()
                    if let planet {
                        Image(systemName: PlanetIcon.symbol(for: planet))
                            .foregroundStyle(PlanetIcon.tint(for: planet))
                    }
                    if !isOfficial {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }
            }
            .disabled(isOfficial)
        } footer: {
            if isOfficial {
                Text("官方行星使用 Core 内置配置，不支持修改。")
            }
        }
    }

    // MARK: - 只读信息

    private var infoSection: some View {
        Section {
            row("World ID", app.planetWorldIds[planetId] ?? "—")
            row("节点 ID", nodeIDText)
            if let planet {
                row("类型", isOfficial ? "官方" : "私有")
                // "文件"项无意义，隐藏。
                // if let fileName = planet.fileName {
                //     row("文件", fileName)
                // }
                if let info = PlanetImporter.inspectPlanetFile(planet) {
                    row("文件大小", ByteCountFormatter.string(fromByteCount: Int64(info.fileSize),
                                                              countStyle: .file))
                    row("修订时间", Self.timestampText(info.timestamp))
                }
            }
        } footer: {
            Text("节点身份与行星绑定，仅隧道正在使用的行星能读取到节点 ID。")
        }
    }

    private var nodeIDText: String {
        // 当前激活行星优先显示实时值，其余/离线回退到缓存。
        if planetId == app.activePlanetId, !app.nodeId.isEmpty { return app.nodeId }
        return app.planetNodeIds[planetId] ?? "—"
    }

    private static func timestampText(_ ts: UInt64) -> String {
        guard ts > 0 else { return "—" }
        // ZeroTier World 时间戳为毫秒。
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - 诊断入口

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                PeerListView()
            } label: {
                Label("查看 Peers", systemImage: "person.2")
            }
            .disabled(planetId != app.activePlanetId)
            NavigationLink {
                MoonView()
            } label: {
                Label("管理卫星节点", systemImage: "moon.stars")
            }
        } footer: {
            Text("Peers 来自隧道的实时连接，仅隧道正在使用的行星可查看。")
        }
    }

    // MARK: - 操作

    private func saveName() {
        guard let planet, name != planet.name else { return }
        do {
            try PlanetImporter.rename(planet, to: name)
            app.reloadConfig()
        } catch {
            alert = error.localizedDescription
        }
    }

    /// 删除顺序对齐原 PlanetListView：激活中先停 VPN，级联清理由 AppConfigStore.deletePlanet 完成。
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
