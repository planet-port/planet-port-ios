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
                        Text("planet.delete")
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
                            color: planet?.iconColor) { animal, color in
                do {
                    try PlanetImporter.updateIcon(planet ?? .official, icon: animal, color: color)
                    app.reloadConfig()
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
        .confirmationDialog("planet.delete.confirmTitle", isPresented: $showDelete, titleVisibility: .visible) {
            Button("planet.delete.confirmAction", role: .destructive) { deletePlanet() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("common.irreversible")
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
            row(loc("planet.info.nodeId"), nodeIDText)
            if let planet {
                row(loc("common.type"),
                    isOfficial ? loc("planet.info.officialKind")
                               : loc("planet.info.customKind"))
                // "文件"项无意义，隐藏。
                // if let fileName = planet.fileName {
                //     row("文件", fileName)
                // }
                if let info = PlanetImporter.inspectPlanetFile(planet) {
                    row(loc("planet.info.fileSize"), locFileSize(info.fileSize))
                    row(loc("planet.info.revision"), Self.timestampText(info.timestamp))
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

    private static func timestampText(_ ts: UInt64) -> String {
        guard ts > 0 else { return "—" }
        // ZeroTier World 时间戳为毫秒。
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        // 格式化器不走 SwiftUI locale 环境，显式带应用语言（单位/日期与文案一致）。
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
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
