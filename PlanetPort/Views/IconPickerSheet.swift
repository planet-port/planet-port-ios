import SwiftUI

/// SF Symbol 图标选择器（iOS 16 无原生 symbolPicker）。
struct IconPickerSheet: View {
    let current: String
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(PlanetIcon.catalog, id: \.self) { symbol in
                        Button {
                            onSelect(symbol)
                            dismiss()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: symbol)
                                    .font(.title3)
                                    .frame(height: 28)
                                if symbol == current {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                } else {
                                    Color.clear.frame(height: 15)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(uiColor: .secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("icon.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("icon.reset") {
                        onSelect(nil)
                        dismiss()
                    }
                }
            }
        }
    }
}
