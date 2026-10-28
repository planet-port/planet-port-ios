import SwiftUI

/// 末位"添加"页:身份预览区(图标 + 行内名称编辑 + 随机按钮)+ 大标题 + 内嵌表单,
/// 与行星页的布局语言刻意区分,一眼可辨"这是创建流程"。
/// 预览名称与 HomeView 共享(Binding):由本页生成/去重,父级无需参与。
struct AddPlanetPage: View {
    @EnvironmentObject private var app: AppState
    @Binding var previewName: String
    /// 是否停在本页(HomeView 传入 pagerSelection == addTag,与 FAB 隐藏同源)。
    let isCurrentPage: Bool
    /// 表单入场动画状态(false=下方 120pt 待入场)。
    @State private var formShown = false

    /// 身份状态:动物 key + 底色 hex。名称未被用户手动编辑前跟随动物本地化名。
    @State private var animal = PlanetIcon.randomAnimal()
    @State private var colorHex = PlanetIcon.randomColorHex()
    @State private var nameEditedByUser = false
    /// 扫码预填过身份：滑回不重掷，保留至添加成功或重新扫码。
    @State private var prefilled = false
    @State private var showIconSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                previewIdentity
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                header
                    .padding(.horizontal, 20)
                AddPlanetForm(name: $previewName, animal: $animal, colorHex: $colorHex,
                              isCurrentPage: isCurrentPage, onPrefill: { prefilled = true }) { profile in
                    app.reloadConfig()
                    app.selectPlanet(profile)
                    prefilled = false
                    // 添加成功后重掷身份,避免与刚添加的行星同名/同图。
                    rollIdentity()
                }
                .padding(.horizontal, 20)
                .offset(y: formShown ? 0 : 120)
                .opacity(formShown ? 1 : 0)
            }
            .padding(.top, HomeMetrics.pageTopPadding)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.immediately)
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            // 每次进入重掷身份：未添加就离开视为放弃，下次进来重新随机；
            // 扫码预填的身份例外——保留至添加成功或重新扫码（与
            // pendingData 的 5 分钟保留语义对齐）。
            if !prefilled { rollIdentity() }
        }
        .onChange(of: isCurrentPage) { current in
            if current {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.15)) {
                    formShown = true
                }
            } else {
                formShown = false
            }
        }
        .sheet(isPresented: $showIconSettings) {
            IconPickerSheet(animal: animal, color: colorHex) { newAnimal, newColor in
                animal = newAnimal
                colorHex = newColor
                syncNameWithAnimal()
            }
        }
    }

    /// 身份预览区:72pt 图标(点击弹图标设置)+ 行内名称编辑 + 随机按钮(重掷
    /// 图形+底色)。虚线边框沿用原预览语义:"尚未创建"的占位形态。
    private var previewIdentity: some View {
        VStack(spacing: 12) {
            Button {
                showIconSettings = true
            } label: {
                Image("animal-\(animal)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .frame(width: 72, height: 72)
                    .background(Color(hex: colorHex) ?? .gray,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.icon"))

            HStack(spacing: 8) {
                TextField(loc("addplanet.namePlaceholder"), text: $previewName)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: previewName) { newValue in
                        if newValue != PlanetIcon.localizedName(animal) {
                            nameEditedByUser = true
                        }
                    }
                Button {
                    rollIdentity()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.body.weight(.medium))
                        .frame(width: 38, height: 38)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("addplanet.randomIcon"))
            }
            .frame(maxWidth: 260)
        }
        .padding(14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
        }
    }

    /// 标题:headline 主标题 + footnote 副指引,与行星页的低调计数行拉开层级。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("planet.add.title")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("addplanet.subtitle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 重掷身份:随机动物(本地化名与现有行星去重)+ 随机底色;名称未手动
    /// 编辑过则跟随动物本地化名。
    private func rollIdentity() {
        animal = PlanetIcon.randomAnimal(excludingNames: Set(app.planets.map(\.name)))
        colorHex = PlanetIcon.randomColorHex()
        nameEditedByUser = false
        previewName = PlanetIcon.localizedName(animal)
    }

    /// 手动选图形后:名称未手动编辑过则跟随(不去重,名称冲突由用户改名)。
    private func syncNameWithAnimal() {
        guard !nameEditedByUser else { return }
        previewName = PlanetIcon.localizedName(animal)
    }
}
