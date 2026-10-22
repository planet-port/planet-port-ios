import SwiftUI

private enum HomeRoute: Hashable {
    case network(String)
    case settings
    case planetSettings(String)
}

/// 首页：固定毛玻璃区（标题 + 分页圆点）+ 整页 TabView 横向分页（相册式平移）。
/// 每个 Planet 一页：卡片 + 计数行 + 网络列表；末位是"添加"页。
/// 横滑翻页、轴锁、跟手阻尼、边缘回弹全部交给 TabView 原生分页；
/// 圆点/外部切换走 binding 内的动画事务，翻页必有动画。
/// 行内导航用 onTapGesture（位移即失败），滑动不会误开详情页。
/// 打开网络开关时才把该 Planet 应用到隧道。
/// 标题为左对齐大字：App 名；有活跃连接且浏览的不是活跃 Planet 时，
/// 设置按钮一侧显示当前行星（🔗 前导），点击快速切回。
struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @State private var showJoin = false
    @State private var errorAlert: String?
    @State private var errorTitle = "提示"
    @State private var pendingNetworks: Set<String> = []
    /// 切换确认弹窗（单网络接入：打开新网络时已有其它网络在用）。
    @State private var switchConfirmCurrent: NetworkEntry?
    @State private var switchConfirmTarget: NetworkEntry?
    /// 无线数据权限被拒提示（2 小时限流）。
    @State private var permissionDenied = false
    @State private var permissionChecker: CellularPermissionChecker?
    @State private var path: [HomeRoute] = []
    @State private var pagerSelection: String = AppConfigStore.selectedPlanetId
    /// 添加页表单与预览卡片共享的名称（进入添加页时随机生成并与现有行星去重）。
    @State private var addPreviewName = ""
    /// 底部安全区高度：启动初期窗口未就绪取不到，兜底 34（主流全面屏），
    /// 场景激活后重读刷新，避免列表"2~3 秒后才撑满"。
    @State private var bottomInset: CGFloat = 34
    /// FAB 当前中心点：nil = 默认右下；拖动吸附后持久化，启动恢复。
    // （状态移入 FabButton 独立视图，拖动每帧只重绘按钮自身，不触发首页整体重算，保证跟手。）

    fileprivate static let addTag = "__add__"

    /// 页面内容顶部固定间距 = 标题区高度 64 + 24 空隙（原 12，整体再下移 12）。
    /// 标题区高度为常量：6 顶距 + 36 标题行（设置按钮撑高）+ 4 行距 + 6 圆点行 + 12 底距。
    /// 标题区任何子视图（行星提示、圆点数量）变化都不改变该高度。
    private static let pageTopPadding: CGFloat = 88

    /// 窗口底部安全区高度（Home 指示条），随机型 34/20/0pt，动态补偿列表视口用。
    /// 不过滤场景激活状态：冷启动首帧场景还未 active，过滤会导致头几秒读到 0。
    private static func readBottomSafeInset() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        return scene?.keyWindow?.safeAreaInsets.bottom ?? 34
    }

    private var pagerBinding: Binding<String> {
        Binding(
            get: { pagerSelection },
            set: { newValue in
                // 动画事务放进 set：圆点/外部跟随等程序化切换也驱动分页平移动画。
                withAnimation(.easeInOut(duration: 0.25)) {
                    pagerSelection = newValue
                }
            })
    }

    var body: some View {
        NavigationStack(path: $path) {
            TabView(selection: pagerBinding) {
                ForEach(app.planets) { planet in
                    planetPage(planet)
                        .tag(planet.id)
                }
                addPage
                    .tag(Self.addTag)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // 全屏页面：分页容器延伸到屏幕物理底部，列表才能撑满（页内单独 ignore 会被
            // TabView 的安全区裁剪，必须在外层忽略）。
            .ignoresSafeArea(edges: .bottom)
            // 固定毛玻璃区：标题 + 分页圆点，页面内容从其下方滚过（顶部间距为固定常量，
            // 见 pageTopPadding 说明；safeAreaInset 与分页 TabView 不兼容会裁掉页面）。
            .overlay(alignment: .top) {
                headerZone
            }
            // 背景：插画 + 薄纱 + 重力视差（仅背景动，前景 UI 不动）。
            .background { HomeParallaxBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .overlay {
                // 新增 Planet 页不显示添加网络按钮。
                if pagerSelection != Self.addTag {
                    fabLayer
                }
            }
            .sheet(isPresented: $showJoin) {
                JoinNetworkSheet()
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .network(let id):
                    if let entry = app.networks.first(where: { $0.networkId == id }) {
                        NetworkDetailView(entry: entry)
                    } else {
                        Text("网络不存在")
                    }
                case .settings: PrefsView()
                case .planetSettings(let id): PlanetSettingsView(planetId: id)
                }
            }
            .alert(errorTitle, isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } })) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorAlert ?? "")
                }
            // 切换网络确认（单网络接入）
            .alert("切换网络", isPresented: Binding(
                get: { switchConfirmTarget != nil },
                set: { if !$0 { switchConfirmTarget = nil; switchConfirmCurrent = nil } })) {
                    Button("切换", role: .destructive) { confirmSwitchNetwork() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("当前已连接「\(displayName(switchConfirmCurrent))」，切换到「\(displayName(switchConfirmTarget))」？")
                }
            // 无线数据权限被拒提示
            .alert("无法使用网络", isPresented: $permissionDenied) {
                Button("去设置") { CellularPermissionChecker.openSettings() }
                Button("知道了", role: .cancel) {}
            } message: {
                Text("PlanetPort 未获得无线数据权限，VPN 将无法连接。请到 设置 → 蜂窝网络 → PlanetPort，选择「WLAN 与蜂窝网络」。")
            }
            .onChange(of: app.networkStatuses) { statuses in
                guard app.selectedPlanetId == app.activePlanetId else { return }
                for (nwid, status) in statuses {
                    // "需要认证"/"拒绝访问"= 首次加入待控制器授权，属正常流程，不弹窗，
                    // 状态行显示"待授权"。
                    if let name = app.networks.first(where: { $0.networkId == nwid })?.networkName,
                       ["网络不存在", "端口错误", "客户端过旧"].contains(status) {
                        errorTitle = "网络状态异常"
                        errorAlert = "网络 \(name)：\(status)"
                        break
                    }
                }
            }
            .onChange(of: pagerSelection) { value in
                if let planet = app.planets.first(where: { $0.id == value }) {
                    // 延后一拍执行配置重载，避免同步磁盘 IO 打断翻页动画。
                    Task { @MainActor in
                        app.selectPlanet(planet)
                    }
                }
            }
            .onChange(of: app.selectedPlanetId) { id in
                // 外部变化（如设置页删除后回退）时跟随。
                if id != pagerSelection, app.planets.contains(where: { $0.id == id }) {
                    pagerSelection = id
                }
            }
            // 启动/场景激活时重读底部安全区，修复首帧列表未撑满；
            // 同时校准分页到上次浏览的行星（selectPlanet 已落盘，此处兜底）。
            .onAppear {
                bottomInset = Self.readBottomSafeInset()
                if pagerSelection != app.selectedPlanetId,
                   app.planets.contains(where: { $0.id == app.selectedPlanetId }) {
                    pagerSelection = app.selectedPlanetId
                }
                startPermissionCheck()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                bottomInset = Self.readBottomSafeInset()
            }
        }
    }

    // MARK: - 固定区（标题 + 圆点）

    /// 左对齐大标题 + 分页圆点，共享一层毛玻璃底（覆盖状态栏，底缘渐隐）。
    private var headerZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("PlanetPort")
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                // 有活跃连接且当前浏览的不是活跃 Planet 时才显示，位于设置按钮一侧。
                if showActivePlanetChip {
                    // emoji 比同字号文字显大：单独缩小到 2/3，并与名称间留一空格位。
                    HStack(spacing: 3) {
                        Text("🔗")
                            .font(.system(size: 22 * 0.65 * 2 / 3))
                        Text(app.activePlanet.name)
                            .font(.system(size: 22 * 0.65, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                    // 点击快速切回当前活跃行星的分页。
                    .onTapGesture {
                        switchPager(to: app.activePlanetId)
                    }
                    .accessibilityHint("切换到当前行星分页")
                    .transition(.flyFromPlanetCard)
                    // 翻页事务自带的 easeInOut 会盖掉隐式动画，这里强制 easeOut 曲线。
                    .transaction { $0.animation = .easeOut(duration: 0.28) }
                }
                Button {
                    path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("设置")
            }
            // 出现/隐藏走弹簧动画，驱动 .flyFromPlanetCard 转场。
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showActivePlanetChip)

            indicator
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.85),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea(edges: .top)
        }
    }

    /// 分页 TabView 跳到不相邻页时不产生动画，改为逐页接力切换，全程连续平移。
    private func switchPager(to target: String) {
        let ids = app.planets.map(\.id) + [Self.addTag]
        guard let from = ids.firstIndex(of: pagerSelection),
              let to = ids.firstIndex(of: target), from != to else {
            pagerBinding.wrappedValue = target
            return
        }
        let step = from < to ? 1 : -1
        var current = from
        func next() {
            current += step
            pagerBinding.wrappedValue = ids[current]
            if current != to {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { next() }
            }
        }
        next()
    }

    /// 当前行星提示的显示条件：有活跃连接且浏览的不是活跃 Planet。
    private var showActivePlanetChip: Bool {
        app.vpnRunning && pagerSelection != app.activePlanetId
    }

    /// 指示器：全部同一样式的圆点，数量比 Planet 数多一个（末位代表"添加"）。
    /// 固定在标题下方，不随页面移动。
    private var indicator: some View {
        HStack(spacing: 7) {
            ForEach(app.planets) { planet in
                dot(isSelected: planet.id == pagerSelection, label: "浏览 \(planet.name)") {
                    pagerBinding.wrappedValue = planet.id
                }
            }
            dot(isSelected: pagerSelection == Self.addTag, label: "添加行星") {
                pagerBinding.wrappedValue = Self.addTag
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pagerSelection)
    }

    private func dot(isSelected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Capsule()
            .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.3)))
            .frame(width: isSelected ? 20 : 6, height: 6)
            // 背景方式补足 44pt 热区，不撑大布局。
            .background(Color.clear.frame(width: 44, height: 44).contentShape(Rectangle()))
            .onTapGesture(perform: action)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 分页

    /// 单个 Planet 页：身份区与网络区以区块级间距（28）分隔，仅网络列表纵向滚动。
    /// 间距节奏：区块间 28 / 卡间 12 / 水平边距 20——"透气"来自区块间距对比，不加大所有间距。
    private func planetPage(_ planet: PlanetProfile) -> some View {
        let networks = app.planetNetworks[planet.id] ?? []
        return VStack(spacing: 0) {
            planetCard(planet)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            // 网络区头部：细分隔线 + 计数行，界定身份区与内容区的层级。
            VStack(spacing: 10) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
                networkHeader(count: networks.count)
            }
            .padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 12) {
                    if networks.isEmpty {
                        emptyState
                    } else {
                        ForEach(networks) { entry in
                            networkCard(entry)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                // 底部预留：滚到最底时最后一行要避开 FAB（56 + 底距 20 + 余量）
                // + 全屏后多出的 Home 指示条高度 34。
                .padding(.bottom, 148)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 网络列表视口向下补偿底部安全区高度（Home 指示条，随机型 34/20/0pt），
            // 铺满物理屏幕底；数值动态取自窗口，不硬编码。
            .padding(.bottom, -bottomInset)
            .scrollDismissesKeyboard(.immediately)
        }
        .padding(.top, Self.pageTopPadding)
        // 全屏：页面整体忽略底安全区，滚动视口才真正铺到物理屏幕底
        // （仅靠外层 TabView 忽略无法传递到页内，列表会停在 Home 指示条上沿）。
        .ignoresSafeArea(edges: .bottom)
    }

    /// 末位"添加"页：虚线预览身份区（占位语义）+ 大标题 + 内嵌表单，
    /// 与行星页的布局语言刻意区分，一眼可辨"这是创建流程"。
    private var addPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                addPreviewCard
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                addHeader
                    .padding(.horizontal, 20)
                AddPlanetForm(name: $addPreviewName) { profile in
                    app.reloadConfig()
                    app.selectPlanet(profile)
                    // 添加成功后换一个新的随机名，避免与刚添加的行星重名。
                    addPreviewName = PlanetNameSuggest.random(excluding: Set(app.planets.map(\.name)))
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, Self.pageTopPadding)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.immediately)
        // 与行星分页一致：忽略底安全区，页面铺到物理屏幕底。
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if addPreviewName.isEmpty {
                addPreviewName = PlanetNameSuggest.random(excluding: Set(app.planets.map(\.name)))
            }
        }
    }

    private func planetCard(_ planet: PlanetProfile) -> some View {
        PlanetCardView(planet: planet,
                       activePlanetName: app.activePlanet.name,
                       isActive: planet.id == app.activePlanetId,
                       app: app)
            // 整行热区（含空白处）：身份区点击进入行星设置。
            .contentShape(Rectangle())
            .onTapGesture {
                app.selectPlanet(planet)
                path.append(.planetSettings(planet.id))
            }
    }

    /// 添加页的预览身份区：虚线边框占位形态，信息随表单实时同步。
    private var addPreviewCard: some View {
        let displayName = addPreviewName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = PlanetProfile(id: "preview-\(displayName.isEmpty ? "planet" : displayName)",
                                    name: displayName.isEmpty ? "新行星" : displayName,
                                    kind: .custom, fileName: nil)
        return PlanetCardView(planet: profile, activePlanetName: "", isActive: false,
                              app: app, isPreview: true)
    }

    // MARK: - 网络

    // MARK: - FAB

    private var fabLayer: some View {
        FabButton(action: { showJoin = true })
    }

    /// 计数行：网络区头部，紧贴细分隔线下方。
    private func networkHeader(count: Int) -> some View {
        Text("网络 · \(count)")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 新增页标题：headline 主标题 + footnote 副指引，与行星页的低调计数行拉开层级。
    private var addHeader: some View {
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("这颗行星还没有网络")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text("点击此处或右下角 + 添加")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { showJoin = true }
    }

    private func networkCard(_ entry: NetworkEntry) -> some View {
        HStack(spacing: 12) {
            // 用 onTapGesture 而非 NavigationLink：位移超过阈值即失败，
            // 横滑翻页不会误开详情页。
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.networkName.isEmpty ? entry.networkId : entry.networkName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.networkId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                // 状态行：IP 紧跟状态文本之后，复制按钮在 IP 后面。
                HStack(spacing: 8) {
                    Circle()
                        .fill(colorFor(statusText(entry)))
                        .frame(width: 6, height: 6)
                    Text(statusText(entry))
                        .font(.caption)
                        .foregroundStyle(colorFor(statusText(entry)))

                    if app.selectedPlanetId == app.activePlanetId,
                       let addresses = app.networkConfigs[entry.networkId]?.assignedAddrs,
                       !addresses.isEmpty {
                        Text(addresses.prefix(2).joined(separator: "  "))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        // 复制按钮：点击复制首个分配 IP。
                        Button {
                            UIPasteboard.general.string = addresses.first ?? ""
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .padding(3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("复制 IP")
                    } else {
                        // 无地址数据（未连接/非活跃行星）用 "-" 占位。
                        Text("-")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                path.append(.network(entry.networkId))
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = entry.networkId
                } label: {
                    Label("复制 ID", systemImage: "doc.on.doc")
                }
            }

            if pendingNetworks.contains(entry.networkId) {
                ProgressView()
                    .frame(width: 44)
            } else {
                Toggle("", isOn: Binding(
                    get: { networkAppearsActive(entry) },
                    set: { setNetworkActive(entry, active: $0) }))
                    .labelsHidden()
                    .accessibilityLabel("启用网络 \(entry.networkName.isEmpty ? entry.networkId : entry.networkName)")
            }

            // "更多"箭头固定在最右。
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 非当前隧道 Planet 的网络统一显示为关闭，用户可直接打开以完成切换。
    private func networkAppearsActive(_ entry: NetworkEntry) -> Bool {
        app.selectedPlanetId == app.activePlanetId && entry.lastActivated
    }

    private func statusText(_ entry: NetworkEntry) -> String {
        if app.selectedPlanetId != app.activePlanetId { return "未应用" }
        if !app.vpnRunning { return entry.lastActivated ? "等待 VPN 连接" : "未连接" }
        if !entry.lastActivated { return "未连接" }
        let status = app.networkStatuses[entry.networkId] ?? "等待节点响应"
        // 首次加入需控制器授权（核心报"需要认证"或"拒绝访问"）：统一显示"待授权"。
        return (status == "需要认证" || status == "拒绝访问") ? "待授权" : status
    }

    private func colorFor(_ status: String) -> Color {
        switch status {
        case "在线": return .green
        case "未应用", "等待 VPN 连接", "待授权": return .orange
        case "未连接", "未启用", "等待节点响应": return .secondary
        default: return .orange
        }
    }

    private func setNetworkActive(_ entry: NetworkEntry, active: Bool) {
        guard active else {
            var networks = app.networks
            guard let index = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
            networks[index].lastActivated = false
            AppConfigStore.writeNetworks(networks)
            app.reloadConfig()
            // 关闭后若该行星下已无启用中的网络，同时停掉 VPN。
            if app.selectedPlanetId == app.activePlanetId,
               !networks.contains(where: { $0.lastActivated }) {
                VPNManager.shared.stop()
            }
            return
        }
        // 单网络接入：已有其它网络启用时先确认切换，确认后关旧网接新网。
        if let current = app.networks.first(where: { $0.networkId != entry.networkId && $0.lastActivated }) {
            switchConfirmCurrent = current
            switchConfirmTarget = entry
            return
        }
        performNetworkActivate(entry)
    }

    private func displayName(_ entry: NetworkEntry?) -> String {
        guard let entry else { return "" }
        return entry.networkName.isEmpty ? entry.networkId : entry.networkName
    }

    /// 启动时检测"无线数据"权限：被拒则提示（2 小时内不重复提醒）。
    private func startPermissionCheck() {
        permissionChecker = CellularPermissionChecker {
            guard CellularPermissionChecker.shouldPrompt() else { return }
            CellularPermissionChecker.markPrompted()
            permissionDenied = true
        }
        permissionChecker?.start()
    }

    /// 确认切换：关闭当前网络，接入新网络（单网络接入，同一时刻只保留一个）。
    private func confirmSwitchNetwork() {
        guard let target = switchConfirmTarget else { return }
        performNetworkActivate(target)
    }

    private func performNetworkActivate(_ entry: NetworkEntry) {
        var networks = app.networks
        // 单网络接入：其它网络一律置为未启用。
        for index in networks.indices where networks[index].networkId != entry.networkId {
            networks[index].lastActivated = false
        }
        guard let index = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[index].lastActivated = true
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()

        // 快速路径：同行星且隧道在跑——writeNetworks 已发配置变更通知，
        // extension 自动增量 join/leave（不重启核心/VPN），无需再走 VPN 启动流程。
        if app.selectedPlanetId == app.activePlanetId && app.vpnRunning {
            pendingNetworks.insert(entry.networkId)
            Task { @MainActor in
                // 给 extension 一个响应窗口，避免开关上的加载圈一闪而过
                try? await Task.sleep(nanoseconds: 600_000_000)
                pendingNetworks.remove(entry.networkId)
            }
            return
        }

        if !AppGroup.defaults.bool(forKey: AppGroup.prefAllowCellular), isCellular() {
            errorTitle = "移动数据未开启"
            errorAlert = "当前使用移动数据，未在设置中允许移动数据"
        }

        pendingNetworks.insert(entry.networkId)
        app.applySelectedPlanetAndStartVPN { ok, error in
            Task { @MainActor in
                pendingNetworks.remove(entry.networkId)
                app.reloadConfig()
                if !ok {
                    errorTitle = "无法启动 VPN"
                    errorAlert = error ?? "VPN 启动失败"
                }
            }
        }
    }

    private func isCellular() -> Bool {
        // 现阶段仍沿用原项目占位；后续可用 NWPathMonitor 接入真实链路判断。
        false
    }
}

// MARK: - 当前行星提示的出现转场

/// 出现时从下方 10pt 处淡入上移，隐藏时反向下移淡出。
private extension AnyTransition {
    static let flyFromPlanetCard = AnyTransition.modifier(
        active: FlyFromPlanetCardModifier(active: true),
        identity: FlyFromPlanetCardModifier(active: false))
}

private struct FlyFromPlanetCardModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .offset(y: active ? 10 : 0)
    }
}

// MARK: - FAB（可拖动 + 左右吸附 + 位置记忆）

/// 独立视图承载拖动状态：拖动每帧只重绘按钮自身，不触发首页（TabView 分页）重算，保证跟手。
private struct FabButton: View {
    let action: () -> Void

    /// 当前中心点：nil = 默认右下；拖动吸附后持久化，启动恢复。
    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragging = false

    /// FAB 半径 28；左右吸附与屏幕边框保持 22 安全距离；垂直活动范围：标题区以下 到 底距 54。
    private static let radius: CGFloat = 28
    private static let sideMargin: CGFloat = 22
    private static let bottomMargin: CGFloat = 54
    private static let topLimit: CGFloat = 88
    private static let xKey = "HomeView.fab.x"
    private static let yKey = "HomeView.fab.y"

    var body: some View {
        GeometryReader { geo in
            label
                .position(position(in: geo.size))
                .gesture(dragGesture(size: geo.size))
                // 首次布局 GeometryReader 尺寸是 0×0，此时恢复会把坐标 clamp 成负值
                // （表现为每次打开都在左上角）；必须等真实尺寸就绪再恢复。
                .onAppear { restoreIfNeeded(in: geo.size) }
                .onChange(of: geo.size) { size in
                    restoreIfNeeded(in: size)
                }
        }
    }

    private var label: some View {
        Image(systemName: "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(.tint, in: Circle())
            .shadow(color: .black.opacity(dragging ? 0.3 : 0.25),
                    radius: dragging ? 14 : 10, y: 5)
            // 拖动时轻微缩小，松手弹回——拿起/放下的手感。
            .scaleEffect(dragging ? 0.95 : 1)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityLabel("添加网络")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: 位置

    /// 默认右下角（与原固定位置一致：trailing 22 + bottom 54）。
    private func defaultPosition(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width - Self.sideMargin - Self.radius,
                y: size.height - Self.bottomMargin - Self.radius)
    }

    /// 位置约束：水平不越过左右安全边距，垂直在标题区以下、底部安全距以上。
    /// 尺寸未就绪（0×0）时原样返回，避免 clamp 出负值。
    private func clamp(_ p: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return p }
        return CGPoint(x: min(max(p.x, Self.sideMargin + Self.radius),
                              size.width - Self.sideMargin - Self.radius),
                       y: min(max(p.y, Self.topLimit + Self.radius),
                              size.height - Self.bottomMargin - Self.radius))
    }

    private func position(in size: CGSize) -> CGPoint {
        clamp(center ?? defaultPosition(size), in: size)
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = position(in: size)
                }
                let start = dragStart ?? .zero
                // 跟手弹簧：与吸附动画同款曲线（阻尼 0.7），时间稍长（0.5 vs 0.35），
                // 手感统一且更绵柔。
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7, blendDuration: 0)) {
                    dragging = true
                    center = clamp(CGPoint(x: start.x + value.translation.width,
                                           y: start.y + value.translation.height), in: size)
                }
            }
            .onEnded { _ in
                dragStart = nil
                var p = position(in: size)
                // 松手水平吸附到较近的一侧；苹果经典 spring 曲线（轻微回弹的阻尼弹簧）。
                p.x = p.x < size.width / 2
                    ? Self.sideMargin + Self.radius
                    : size.width - Self.sideMargin - Self.radius
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7, blendDuration: 0)) {
                    dragging = false
                    center = p
                }
                save(p)
            }
    }

    // MARK: 持久化

    private func save(_ p: CGPoint) {
        UserDefaults.standard.set(Double(p.x), forKey: Self.xKey)
        UserDefaults.standard.set(Double(p.y), forKey: Self.yKey)
    }

    /// 仅在无状态且尺寸就绪时恢复一次；首次安装无记录则保持 nil → 默认右下。
    private func restoreIfNeeded(in size: CGSize) {
        guard center == nil, size.width > 0, size.height > 0 else { return }
        let x = UserDefaults.standard.double(forKey: Self.xKey)
        let y = UserDefaults.standard.double(forKey: Self.yKey)
        guard x > 0, y > 0 else { return }
        center = clamp(CGPoint(x: x, y: y), in: size)
    }
}
