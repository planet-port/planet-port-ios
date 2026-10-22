import SwiftUI
import UniformTypeIdentifiers

/// 内嵌在首页网络列表位置的添加 Planet 表单（右划到末位占位页时显示）。
/// 卡片预览与表单实时同步；文件/URL 先就绪，再点"添加"落库。
struct AddPlanetForm: View {
    /// 与首页 Pager 的预览卡片共享的名称。
    @Binding var name: String
    let onImported: (PlanetProfile) -> Void

    @EnvironmentObject private var app: AppState

    @State private var url = ""
    @State private var showFilePicker = false
    @State private var downloading = false
    /// 已就绪、等待"添加"的 Planet 文件内容。
    @State private var pendingData: Data?
    @State private var alert: String?

    var body: some View {
        VStack(spacing: 16) {
            formCard
            addButton
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            guard case .success(let fileURL) = result else {
                if case .failure(let error) = result { alert = error.localizedDescription }
                return
            }
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: fileURL)
                try validate(data)
                pendingData = data
            } catch {
                alert = error.localizedDescription
            }
        }
        .alert("导入失败", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
    }

    // MARK: - 表单卡片（信息录入）

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题行已由首页新增页的"添加私有行星"统一显示，此处隐藏避免重复。
            // HStack(spacing: 10) {
            //     Image(systemName: "globe.badge.plus")
            //         .font(.title3)
            //         .foregroundStyle(.tint)
            //     Text("添加私有行星")
            //         .font(.system(size: 16, weight: .semibold))
            // }

            // 名称 + 随机换名
            HStack(spacing: 10) {
                field($name, placeholder: "行星名称")
                Button {
                    name = PlanetNameSuggest.random(excluding: Set(app.planets.map(\.name)))
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.medium))
                        .frame(width: 42, height: 42)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("换个随机名称")
            }

            // 选择文件独占一行：padding/背景放进 label，整块组件（含背景）都是点击热区。
            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Label("选择行星文件", systemImage: "doc")
                    Spacer()
                    if let data = pendingData {
                        Text("已就绪 · \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            // URL：输入框左，导入按钮右（按钮高度与输入框一致）
            HStack(spacing: 10) {
                field($url, placeholder: "或输入行星文件地址", keyboard: .URL)
                Button {
                    importFromURL()
                } label: {
                    Group {
                        if downloading {
                            ProgressView()
                        } else {
                            Text("导入")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(width: 56, height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(url.isEmpty || downloading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - 主操作（独立于信息卡片之外）

    private var addButton: some View {
        Button {
            add()
        } label: {
            Text("添加行星服务器")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AnyShapeStyle(.tint)))
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .opacity(canAdd ? 1 : 0.4)
        // 宽度最大 84%；与上方内容留出一行文字高度的空白。
        .padding(.horizontal, UIScreen.main.bounds.width * 0.08)
        .padding(.top, 20)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        pendingData != nil && !trimmedName.isEmpty
    }

    private func field(_ binding: Binding<String>, placeholder: String,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: binding)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func validate(_ data: Data) throws {
        guard data.first == 0x01 else { throw PlanetImporter.ImportError.badHeader }
    }

    private func add() {
        guard let data = pendingData else { return }
        // 相同 World ID 视为同一个 Planet，禁止重复创建。
        if let worldId = PlanetImporter.worldId(of: data),
           PlanetImporter.existingWorldIds().contains(worldId) {
            alert = "已存在相同的 Planet（World ID \(String(format: "%016llx", worldId))），不能重复添加。"
            return
        }
        do {
            let profile = try PlanetImporter.importPlanetData(data, name: trimmedName)
            pendingData = nil
            url = ""
            onImported(profile)
        } catch {
            alert = error.localizedDescription
        }
    }

    private func importFromURL() {
        downloading = true
        PlanetImporter.downloadPlanetFile(url) { result in
            Task { @MainActor in
                downloading = false
                switch result {
                case .success(let data):
                    do {
                        try validate(data)
                        pendingData = data
                    } catch {
                        alert = error.localizedDescription
                    }
                case .failure(let error):
                    alert = error.localizedDescription
                }
            }
        }
    }
}

/// 随机 Planet 命名：知名星球（太阳系 + 星战等流行文化），生成时与现有名称去重。
enum PlanetNameSuggest {
    private static let names = [
        "Mars", "Venus", "Jupiter", "Saturn", "Mercury", "Neptune", "Uranus",
        "Tatooine", "Hoth", "Endor", "Naboo", "Coruscant", "Alderaan", "Bespin", "Dagobah",
        "Pandora", "Vulcan", "Krypton", "Asgard", "Arrakis", "Cybertron", "Gallifrey",
    ]

    static func random(excluding used: Set<String> = []) -> String {
        let candidates = names.filter { !used.contains($0) }
        return (candidates.isEmpty ? names : candidates).randomElement() ?? "Mars"
    }
}
