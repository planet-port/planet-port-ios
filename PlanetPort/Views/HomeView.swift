import SwiftUI
import os

private enum HomeRoute: Hashable {
    case network(String)
    case settings
    case planetSettings(String)
}

/// 跨行星切换弹窗的阶段：确认（用户选择）→ 断开中（等待旧 VPN 确认断开）。
/// 用自定义弹窗而非系统 alert：alert 点按钮即自动关闭，无法在断开过程中
/// 保持展示并告知用户当前状态。
private enum SwitchPlanetPhase {
    case confirm(NetworkEntry)
    case disconnecting(NetworkEntry)

    /// 阶段持有的目标网络（两阶段都需要）。
    var target: NetworkEntry {
        switch self {
        case .confirm(let e), .disconnecting(let e): return e
        }
    }
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
    /// 卡片状态色（NetworkCardStatus）在 body 内计算，随主题派生开关变化。
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showJoin = false
    @State private var errorAlert: String?
    @State private var errorTitle = loc("common.notice")
    @State private var pendingNetworks: Set<String> = []
    /// 超出并发上限的确认弹窗（软上限：多开增加耗电，可强制开启）。
    @State private var limitConfirmTarget: NetworkEntry?
    /// 跨行星切换弹窗阶段（当前行星隧道在跑时，开启他行星网络需先确认切换）。
    @State private var switchPhase: SwitchPlanetPhase?
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
    /// 背景视差开关（默认开启，仅设置了背景图时生效）
    @AppStorage(AppGroup.prefParallaxEnabled) private var parallaxEnabled = true

    fileprivate static let addTag = "__add__"
    /// 网络开关诊断日志（Console 按 subsystem 过滤）。
    private static let netLog = Logger(subsystem: "cn.imgozi.i.PlanetPort", category: "NetworkToggle")

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
            // 背景：自定义背景图 + 薄纱 + 重力视差（无图时纯页面底色）。
            .background { HomeParallaxBackground(image: app.backgroundImage,
                                                 parallaxEnabled: parallaxEnabled) }
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
                        Text("network.status.notFound")
                    }
                case .settings: PrefsView()
                case .planetSettings(let id): PlanetSettingsView(planetId: id)
                }
            }
            .alert(errorTitle, isPresented: Binding(
                get: { errorAlert != nil },
                set: { if !$0 { errorAlert = nil } })) {
                    Button("common.ok", role: .cancel) {}
                } message: {
                    Text(errorAlert ?? "")
                }
            // 并发上限确认（软上限：可强制开启）
            .alert("home.alert.openMore", isPresented: Binding(
                get: { limitConfirmTarget != nil },
                set: { if !$0 { limitConfirmTarget = nil } })) {
                    Button("home.alert.openAnyway", role: .destructive) { confirmOpenBeyondLimit() }
                    Button("common.cancel", role: .cancel) {}
                } message: {
                    Text("home.alert.limitConfirm \(displayName(limitConfirmTarget))")
                }
            // 跨行星切换弹窗（行星互斥：切换会断开当前行星的全部连接）。
            // 自定义弹窗承载两个阶段：确认 → 断开中，见 SwitchPlanetPhase。
            .overlay { switchPlanetDialog }
            // 无线数据权限被拒提示
            .alert("home.alert.noNetworkAccess", isPresented: $permissionDenied) {
                Button("home.alert.goSettings") { CellularPermissionChecker.openSettings() }
                Button("home.alert.gotIt", role: .cancel) {}
            } message: {
                Text("home.alert.cellularDeniedMessage")
            }
            .onChange(of: app.networkStatuses) { statuses in
                guard app.selectedPlanetId == app.activePlanetId else { return }
                for (nwid, status) in statuses {
                    // 待授权（需要认证/拒绝访问）= 首次加入待控制器授权，
                    // 属正常流程，不弹窗，状态行显示"待授权"。
                    if let name = app.networks.first(where: { $0.networkId == nwid })?.networkName,
                       status.isAlertable {
                        errorTitle = loc("home.alert.networkStatusError")
                        errorAlert = loc("home.alert.networkStatus \(name): \(status.displayName)")
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
            HStack(alignment: .top, spacing: 5.5) {
                // Logo 独占左侧成块（约 40pt，覆盖右侧标题行 + 指示器两行高度），
                // 连续圆角修饰。
                Image("PlanetPortLogo")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                // 右列：标题行在顶（顶部对齐 logo 顶再偏下 3pt），
                // 指示器沉底（底部对齐 logo 底）。
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Planet Port")
                            .font(.system(size: 22, weight: .bold))
                        Spacer()
                // 有活跃连接且当前浏览的不是活跃 Planet 时才显示，位于设置按钮一侧。
                if showActivePlanetChip {
                    // emoji 比同字号文字显大：单独缩小到 2/3，并与名称间留一空格位。
                    // 胶囊样式：与毛玻璃标题栏隔离，一眼可辨"当前生效行星"。
                    HStack(spacing: 3) {
                        Text("🔗")
                            .font(.system(size: 22 * 0.65 * 2 / 3))
                        Text(app.activePlanet.displayName)
                            .font(.system(size: 22 * 0.65, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                    // 点击快速切回当前活跃行星的分页。
                    .onTapGesture {
                        switchPager(to: app.activePlanetId)
                    }
                    .accessibilityHint(Text("home.a11y.activePlanetHint"))
                    .transition(.flyFromPlanetCard)
                    // 翻页事务自带的 easeInOut 会盖掉隐式动画，这里强制 easeOut 曲线。
                    .transaction { $0.animation = .easeOut(duration: 0.28) }
                }
                Button {
                    path.append(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("common.settings"))
                    }
                    // 出现/隐藏走弹簧动画，驱动 .flyFromPlanetCard 转场。
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showActivePlanetChip)

                    Spacer(minLength: 0)

                    indicator
                        // offset 纯视觉位移（不参与布局）：此前用 padding 会被
                        // 右列自然高度吸收（容器长高而非指示器上移），形同没调。
                        .offset(y: -2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 右列高度锁死与 logo 等高：内部 Spacer/位移才有确定的参照系。
                .frame(height: 40)
            }
            .fixedSize(horizontal: false, vertical: true)
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
                dot(isSelected: planet.id == pagerSelection,
                    label: loc("home.a11y.browsePlanet \(planet.displayName)")) {
                    pagerBinding.wrappedValue = planet.id
                }
            }
            dot(isSelected: pagerSelection == Self.addTag, label: loc("planet.add.title")) {
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
                networkHeader(count: networks.count, planet: planet)
            }
            .padding(.horizontal, 20)

            ScrollView {
                VStack(spacing: 12) {
                    if networks.isEmpty {
                        emptyState
                    } else {
                        ForEach(networks) { entry in
                            networkCard(entry, planet: planet)
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
        .padding(.top, HomeMetrics.pageTopPadding)
        // 全屏：页面整体忽略底安全区，滚动视口才真正铺到物理屏幕底
        // （仅靠外层 TabView 忽略无法传递到页内，列表会停在 Home 指示条上沿）。
        .ignoresSafeArea(edges: .bottom)
    }

    /// 末位"添加"页（组件见 AddPlanetPage）。
    private var addPage: some View {
        AddPlanetPage(previewName: $addPreviewName,
                         isCurrentPage: pagerSelection == Self.addTag)
    }

    private func planetCard(_ planet: PlanetProfile) -> some View {
        Button {
            app.selectPlanet(planet)
            path.append(.planetSettings(planet.id))
        } label: {
            PlanetCardView(planet: planet,
                           activePlanetName: app.activePlanet.name,
                           isActive: planet.id == app.activePlanetId,
                           app: app)
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    // MARK: - 网络

    // MARK: - FAB

    private var fabLayer: some View {
        FabButton(action: { showJoin = true })
    }

    /// 计数行：网络区头部，紧贴细分隔线下方。启用网络按实时状态分桶展示
    /// "连接中 X | 已连接 Y"（已连接 = 核心报 OK），计数为 0 的桶不显示，
    /// 全为 0 则不追加。数据取本页行星自己的网络（planetNetworks）。
    private func networkHeader(count: Int, planet: PlanetProfile) -> some View {
        var text = loc("home.network.header \(count)")
        if planet.id == app.activePlanetId && app.vpnRunning {
            let enabled = (app.planetNetworks[planet.id] ?? []).filter {
                $0.lastActivated && app.networkConflicts[$0.networkId] == nil
            }
            let connected = enabled.filter { app.networkStatuses[$0.networkId] == .ok }.count
            let connecting = enabled.count - connected
            var parts: [String] = []
            if connecting > 0 { parts.append(loc("home.network.connecting \(connecting)")) }
            if connected > 0 { parts.append(loc("home.network.connected \(connected)")) }
            if !parts.isEmpty {
                text += " · " + parts.joined(separator: " | ")
            }
        }
        return Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text("home.network.emptyTitle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text("home.network.emptyHint")
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

    private func networkCard(_ entry: NetworkEntry, planet: PlanetProfile) -> some View {
        // 卡片显示值（开关、状态、地址）锚定卡片自己的行星而非全局选中页：
        // 滑页过半时 selection 先行变化，全局判断会让仍可见的旁页卡片
        // 瞬时翻成开启（被掩蔽的 lastActivated 露出）。
        let isActivePlanet = planet.id == app.activePlanetId
        return NetworkCardView(
            entry: entry,
            cardStatus: NetworkCardStatus(entry: entry, app: app, isActivePlanet: isActivePlanet),
            isPending: pendingNetworks.contains(entry.networkId),
            appearsActive: isActivePlanet && entry.lastActivated,
            addresses: isActivePlanet
                ? app.networkConfigs[entry.networkId]?.assignedAddrs.map { String($0.split(separator: "/").first ?? Substring($0)) } : nil,
            onToggle: { setNetworkActive(entry, active: $0) },
            onTap: { path.append(.network(entry.networkId)) })
    }

    private func setNetworkActive(_ entry: NetworkEntry, active: Bool) {
        // 读写一律锚定网络归属的行星（entry.planetId），不依赖全局选中页：
        // 滑页过半时选中态先行变化，按选中页读写会改错/漏改旁页网络。
        let planetId = entry.planetId ?? app.selectedPlanetId
        guard active else {
            var networks = AppConfigStore.readNetworks(planetId: planetId)
            guard let index = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
            networks[index].lastActivated = false
            AppConfigStore.writeNetworks(networks, planetId: planetId)
            app.reloadConfig()
            // 关闭后若该行星下已无启用中的网络，同时停掉 VPN。
            let remaining = networks.filter(\.lastActivated).count
            Self.netLog.info("关闭网络 \(entry.networkId, privacy: .public) planet=\(planetId, privacy: .public) active=\(app.activePlanetId, privacy: .public) 剩余启用 \(remaining)")
            if planetId == app.activePlanetId, remaining == 0 {
                VPNManager.shared.stop()
            }
            return
        }
        // 跨行星开启：行星互斥，当前行星隧道在跑时切换会断开其全部连接，
        // 先确认再走启动流程。
        if planetId != app.activePlanetId, app.vpnRunning {
            switchPhase = .confirm(entry)
            return
        }
        // 软上限：新开网络会超出上限时先确认耗电（可强制开启）。
        let activeCount = AppConfigStore.readNetworks(planetId: planetId)
            .filter { $0.lastActivated && $0.networkId != entry.networkId }.count
        let limit = max(2, AppGroup.defaults.integer(forKey: AppGroup.prefMultiConnectLimit))
        if activeCount >= limit {
            limitConfirmTarget = entry
            return
        }
        performNetworkActivate(entry)
    }

    /// 确认超出软上限开启（耗电提示后仍要开启）。
    private func confirmOpenBeyondLimit() {
        guard let target = limitConfirmTarget else { return }
        performNetworkActivate(target)
    }

    /// 确认跨行星切换：先断开当前 VPN（弹窗保持展示状态），确认断开后
    /// 关闭弹窗，稍作稳定等待再启动新行星。直接 stopVPNTunnel 后立刻启动
    /// 会让旧会话的拆除与新启动竞争，新连接可能被旧拆除打断。
    private func confirmSwitchPlanet() {
        guard let phase = switchPhase else { return }
        let target = phase.target
        Self.netLog.info("确认切换行星：目标网络 \(target.networkId, privacy: .public)，开始断开当前 VPN")
        switchPhase = .disconnecting(target)
        VPNManager.shared.stopAndWait { confirmed in
            Task { @MainActor in
                Self.netLog.info("当前 VPN 断开\(confirmed ? "已确认" : "等待超时")，关闭弹窗并启动新行星")
                // 弹窗关闭与启动之间留一个短暂稳定窗口（50~150ms 量级），
                // 让系统完成旧会话资源回收。
                withAnimation(.easeInOut(duration: 0.15)) { switchPhase = nil }
                try? await Task.sleep(nanoseconds: 100_000_000)
                performNetworkActivate(target)
            }
        }
    }

    /// 跨行星切换弹窗：确认阶段（标题 + 说明 + 双按钮）→ 断开阶段（转圈 + 状态）。
    @ViewBuilder
    private var switchPlanetDialog: some View {
        if let phase = switchPhase {
            ZStack {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                switch phase {
                case .confirm(let target):
                    dialogCard {
                        // 标题与说明：左对齐（系统 alert 同款左对齐排版）。
                        // 说明里的目标/当前网络名用 markdown 加粗（SwiftUI Text
                        // 对 LocalizedStringKey 内联渲染 **bold**）。
                        VStack(spacing: 6) {
                            Text("home.alert.switchPlanet")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("home.alert.switchPlanetMessage \(displayName(target)) \(currentPlanetName)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } footer: {
                        // 系统 alert 同款按钮行：纯文字、平分宽度、细分隔线，
                        // 取消常规字重、确认加粗 + 主配色（tint）
                        HStack(spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { switchPhase = nil }
                            } label: {
                                Text("common.cancel")
                                    .font(.body)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.secondary)
                            Rectangle()
                                .fill(Color.primary.opacity(0.15))
                                .frame(width: 0.5, height: 44)
                            Button {
                                confirmSwitchPlanet()
                            } label: {
                                Text("home.alert.openAnyway")
                                    .font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                case .disconnecting:
                    dialogCard {
                        ProgressView()
                            .controlSize(.large)
                        Text("home.switch.disconnecting")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    /// 弹窗内容统一容器（宽度、留白与系统 alert 观感对齐）。
    /// footer（按钮行）通栏贴卡片底边，上方以分隔线隔开——系统 alert 的
    /// 按钮区就是这种全出血排版，不随内容区留白。
    @ViewBuilder
    private func dialogCard<Content: View, Footer: View>(
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                content()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            if Footer.self != EmptyView.self {
                Divider()
                footer()
            }
        }
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 40)
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }

    private func displayName(_ entry: NetworkEntry?) -> String {
        guard let entry else { return "" }
        return entry.networkName.isEmpty ? entry.networkId : entry.networkName
    }

    /// 当前活跃行星展示名（切换弹窗提示用；官方行星走本地化名）。
    private var currentPlanetName: String {
        app.planets.first(where: { $0.id == app.activePlanetId })?.displayName ?? ""
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

    private func performNetworkActivate(_ entry: NetworkEntry) {
        // 同 setNetworkActive：按网络归属行星读写，多网络联动也限制在该行星内。
        let planetId = entry.planetId ?? app.selectedPlanetId
        var networks = AppConfigStore.readNetworks(planetId: planetId)
        guard let index = networks.firstIndex(where: { $0.networkId == entry.networkId }) else { return }
        networks[index].lastActivated = true
        // 重新手动开启视为用户已知冲突，清除上次的冲突断开记录
        networks[index].lastConflict = nil
        // 多网络联动：启用数 > 1 时默认路由不可用，全部自动关闭并一次性提示
        var routeViaTurnedOff = false
        if networks.filter { $0.lastActivated }.count > 1 {
            for i in networks.indices where networks[i].routeViaZeroTier {
                networks[i].routeViaZeroTier = false
                routeViaTurnedOff = true
            }
        }
        AppConfigStore.writeNetworks(networks, planetId: planetId)
        app.reloadConfig()
        if routeViaTurnedOff {
            errorTitle = loc("home.error.multiNetworkTitle")
            errorAlert = loc("home.error.multiNetworkMessage")
        }

        // 快速路径：网络所属行星就是隧道行星且隧道在跑——writeNetworks 已发配置
        // 变更通知，extension 自动增量 join/leave（不重启核心/VPN），无需再走 VPN 启动流程。
        if planetId == app.activePlanetId && app.vpnRunning {
            pendingNetworks.insert(entry.networkId)
            Task { @MainActor in
                // 给 extension 一个响应窗口，避免开关上的加载圈一闪而过
                try? await Task.sleep(nanoseconds: 600_000_000)
                pendingNetworks.remove(entry.networkId)
            }
            return
        }

        if !AppGroup.defaults.bool(forKey: AppGroup.prefAllowCellular), isCellular() {
            errorTitle = loc("home.error.cellularTitle")
            errorAlert = loc("home.error.cellularMessage")
        }

        pendingNetworks.insert(entry.networkId)
        app.applyPlanetAndStartVPN(planetId) { ok, error in
            Task { @MainActor in
                pendingNetworks.remove(entry.networkId)
                app.reloadConfig()
                if !ok {
                    errorTitle = loc("home.error.vpnStartTitle")
                    errorAlert = error ?? loc("vpn.error.startFallback")
                }
            }
        }
    }

    private func isCellular() -> Bool {
        // 现阶段为固定占位；后续可用 NWPathMonitor 接入真实链路判断。
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
