import SwiftUI

/// 图标设置:分段「图形 / 底色」。图形页 4 列动物网格(深灰磁贴 + 本地化名 +
/// 选中标记);底色页当前预览 + 随机按钮 + 预设色板。选择后点「完成」统一生效。
/// 无「恢复自动」——图标一经选择永久使用,自动算法仅作未设置时的兜底。
struct IconPickerSheet: View {
    /// 当前动物 key(传有效解析结果,如 PlanetIcon.animalKey(for:))。
    let animal: String
    /// 当前底色 hex(nil = 未自定义)。
    let color: String?
    let onSelect: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .graphic
    @State private var selectedAnimal: String
    @State private var selectedColor: String

    enum Tab: Hashable { case graphic, color }

    /// 预设底色:中低亮度、白图形对比度可靠的色板。
    static let palette: [String] = [
        "#b03a3a", "#c0392b", "#d44037", "#c05621",
        "#b45309", "#a16207", "#854d0e", "#15803d",
        "#166534", "#0f766e", "#0e7490", "#155e75",
        "#1d4ed8", "#1e40af", "#3730a3", "#6d28d9",
        "#a21caf", "#9d174d", "#475569", "#334155",
    ]

    init(animal: String, color: String?, onSelect: @escaping (String, String) -> Void) {
        self.animal = animal
        self.color = color
        self.onSelect = onSelect
        _selectedAnimal = State(initialValue: animal)
        _selectedColor = State(initialValue: color ?? PlanetIcon.randomColorHex())
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("icon.title", selection: $tab) {
                    Text("icon.graphic").tag(Tab.graphic)
                    Text("icon.color").tag(Tab.color)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                ScrollView {
                    if tab == .graphic { animalGrid } else { colorGrid }
                }
                .padding(.top, 12)
            }
            .navigationTitle("icon.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        onSelect(selectedAnimal, selectedColor)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - 图形页

    private var animalGrid: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(PlanetIcon.catalog, id: \.self) { key in
                Button {
                    selectedAnimal = key
                } label: {
                    VStack(spacing: 6) {
                        // 白色 PDF 需深色底才可见:磁贴用当前选中底色。
                        Image("animal-\(key)")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 48, height: 48)
                            .background(Color(hex: selectedColor) ?? .gray,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(PlanetIcon.localizedName(key))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: key == selectedAnimal ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(key == selectedAnimal ? Color.accentColor : Color.clear)
                            .frame(height: 14)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        key == selectedAnimal
                            ? Color.accentColor.opacity(0.1)
                            : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    // MARK: - 底色页

    private var colorGrid: some View {
        VStack(spacing: 14) {
            // 当前预览:白动物图 + 预选底色。
            Image("animal-\(selectedAnimal)")
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .frame(width: 72, height: 72)
                .background(Color(hex: selectedColor) ?? .gray,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                selectedColor = PlanetIcon.randomColorHex()
            } label: {
                Label("icon.randomColor", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button {
                        selectedColor = hex
                    } label: {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(height: 44)
                            .overlay(alignment: .topTrailing) {
                                if hex == selectedColor {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}
