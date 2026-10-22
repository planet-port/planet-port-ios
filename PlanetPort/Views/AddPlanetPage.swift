import SwiftUI

/// 末位"添加"页：虚线预览身份区（占位语义）+ 大标题 + 内嵌表单，
/// 与行星页的布局语言刻意区分，一眼可辨"这是创建流程"。
/// 预览名称与 HomeView 共享（Binding）：由本页生成/去重，父级无需参与。
struct AddPlanetPage: View {
    @EnvironmentObject private var app: AppState
    @Binding var previewName: String
    /// 是否停在本页（HomeView 传入 pagerSelection == addTag，与 FAB 隐藏同源）。
    /// 跟手滑入在快滑时事件粒度不足会闪烁，改为落位驱动的固定入场动画：
    /// 到达本页时表单从下方弹簧滑入一次，离开时跟随页面整体滑走。
    let isCurrentPage: Bool
    /// 表单入场动画状态（false=下方 120pt 待入场）。
    @State private var formShown = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                previewCard
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                header
                    .padding(.horizontal, 20)
                AddPlanetForm(name: $previewName) { profile in
                    app.reloadConfig()
                    app.selectPlanet(profile)
                    // 添加成功后换一个新的随机名，避免与刚添加的行星重名。
                    previewName = PlanetNameSuggest.random(excluding: Set(app.planets.map(\.name)))
                }
                .padding(.horizontal, 20)
                // 落位入场：到达本页时弹簧上滑，离开时随页面滑走（无独立退出动画）。
                .offset(y: formShown ? 0 : 120)
                .opacity(formShown ? 1 : 0)
            }
            .padding(.top, HomeMetrics.pageTopPadding)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.immediately)
        // 与行星分页一致：忽略底安全区，页面铺到物理屏幕底。
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if previewName.isEmpty {
                previewName = PlanetNameSuggest.random(excluding: Set(app.planets.map(\.name)))
            }
        }
        // 落位驱动：selection 在滑动过半时即翻转，若立刻播动画，快甩时页面
        // 迅速就位而表单动画已跑了一半，观感即"从中间冒出"。延迟 0.15s 让
        // 表单在页面落位后才开始；取消翻回时复位（延迟期内表单本就未显示）。
        .onChange(of: isCurrentPage) { current in
            if current {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.15)) {
                    formShown = true
                }
            } else {
                formShown = false
            }
        }
    }
}

extension AddPlanetPage {
    /// 预览身份区：虚线边框占位形态，信息随表单实时同步。
    private var previewCard: some View {
        let displayName = previewName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PlanetProfile(id: "preview-\(displayName.isEmpty ? "planet" : displayName)",
                                    name: displayName.isEmpty ? "新行星" : displayName,
                                    kind: .custom, fileName: nil)
        return PlanetCardView(planet: profile, activePlanetName: "", isActive: false,
                              app: app, isPreview: true)
    }

    /// 标题：headline 主标题 + footnote 副指引，与行星页的低调计数行拉开层级。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("添加行星")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("导入 planet 文件，或输入下载地址")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
