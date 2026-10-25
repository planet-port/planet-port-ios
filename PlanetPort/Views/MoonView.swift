import SwiftUI

/// Moon 管理页
struct MoonView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showAdd = false
    @State private var showFilePicker = false
    @State private var errorAlert: String?

    /// 与首页/Peers 一致的卡片行边距。
    private static let cardInsets = EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)

    var body: some View {
        List {
            if app.moons.isEmpty {
                emptyCard
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.cardInsets)
                    .listRowBackground(Color.clear)
            }
            ForEach(app.moons) { moon in
                moonRow(moon)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.cardInsets)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteOrbit(moon)
                        } label: {
                            Label("moon.deleteOrbit", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteOrbit(moon)
                        } label: {
                            Label("moon.deleteOrbit", systemImage: "trash")
                        }
                        Button {
                            UIPasteboard.general.string = String(format: "%016llx", moon.worldId)
                        } label: {
                            Label("moon.copyAddress", systemImage: "doc.on.doc")
                        }
                        if moon.fromFile {
                            Button(role: .destructive) {
                                deleteCache(moon)
                            } label: {
                                Label("moon.deleteCache", systemImage: "doc.bad.gearshape")
                            }
                        }
                    }
            }
        }
        // 去掉系统分组底，页面底色与首页一致。
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("moon.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            addMoonSheet
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url):
                do {
                    let entry = try MoonImporter.importMoonFile(at: url)
                    addMoon(entry)
                } catch {
                    errorAlert = error.localizedDescription
                }
            case .failure(let e):
                errorAlert = e.localizedDescription
            }
        }
        .alert(loc("common.notice"), isPresented: .init(get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(errorAlert ?? "")
        }
    }

    // MARK: - 行

    /// 空态卡：与首页空态同语言。
    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("moon.emptyTitle \(app.selectedPlanet.displayName)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text("moon.emptyHint")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func moonRow(_ moon: MoonEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // 图标 badge：与首页身份区同语言（tint 实底 + 白符号）。
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.tint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(String(format: "%016llx", moon.worldId))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if !moon.fromFile {
                        Text("seed \(String(format: "%016llx", moon.seed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    cacheBadge(moon)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 缓存徽标：已缓存（就绪，绿）/ 未缓存（中性）；文件导入的附 doc 图标。
    private func cacheBadge(_ moon: MoonEntry) -> some View {
        let cached = FileManager.default.fileExists(atPath: moon.cacheFileURL.path)
        return HStack(spacing: 3) {
            if moon.fromFile {
                Image(systemName: "doc.fill")
                    .font(.caption2)
            }
            Text(cached ? loc("moon.cached") : loc("moon.notCached"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(cached ? ThemeManager.shared.success : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((cached ? ThemeManager.shared.success.opacity(0.12) : Color.secondary.opacity(0.12)),
                    in: Capsule())
    }

    // MARK: - 添加 sheet（文件导入 / 手动 orbit 二选一）

    private var addMoonSheet: some View {
        AddMoonSheet(
            onFileImport: {
                showAdd = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showFilePicker = true }
            },
            onManualOrbit: { worldId, seed in
                addMoon(MoonEntry(worldId: worldId, seed: seed, fromFile: false))
                showAdd = false
            })
    }

    // MARK: - 操作

    private func addMoon(_ entry: MoonEntry) {
        var moons = app.moons
        moons.removeAll { $0.worldId == entry.worldId }
        moons.append(entry)
        AppConfigStore.writeMoons(moons)
        app.reloadConfig()
    }

    /// 删除入轨：清记录 + 删缓存（不调 deorbit）
    private func deleteOrbit(_ moon: MoonEntry) {
        var moons = app.moons
        moons.removeAll { $0.worldId == moon.worldId }
        AppConfigStore.writeMoons(moons)
        app.reloadConfig()
    }

    private func deleteCache(_ moon: MoonEntry) {
        try? FileManager.default.removeItem(at: moon.cacheFileURL)
    }
}

/// 添加卫星 的 sheet：文件导入 / 手动 orbit
private struct AddMoonSheet: View {
    let onFileImport: () -> Void
    let onManualOrbit: (UInt64, UInt64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var worldIdText = ""
    @State private var seedText = ""

    private var hex16Valid: (String) -> Bool = { $0.count == 16 && $0.allSatisfy { $0.isHexDigit } }

    var body: some View {
        NavigationStack {
            Form {
                Section("moon.importFileHeader") {
                    Button {
                        onFileImport()
                    } label: {
                        Label("moon.chooseFile", systemImage: "doc")
                    }
                }
                Section("moon.manualHeader") {
                    TextField("moon.worldIdPlaceholder", text: $worldIdText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                    TextField("moon.seedPlaceholder", text: $seedText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                    Button("moon.orbit") {
                        onManualOrbit(UInt64(worldIdText, radix: 16) ?? 0,
                                      UInt64(seedText, radix: 16) ?? 0)
                    }
                    .disabled(!hex16Valid(worldIdText) || !hex16Valid(seedText))
                }
            }
            .navigationTitle("moon.addTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
            }
        }
    }
}
