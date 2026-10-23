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
    @State private var errorTitle = loc("common.notice")
    @State private var pendingNetworks: Set<String> = []
    /// 超出并发上限的确认弹窗（软上限：多开增加耗电，可强制开启）。
    @State private var limitConfirmTarget: NetworkEntry?
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

    // MARK: - 网络

    // MARK: - FAB

    private var fabLayer: some View {
        FabButton(action: { showJoin = true })
    }

    /// 计数行：网络区头部，紧贴细分隔线下方。多网络连接中追加已连接数。
    private func networkHeader(count: Int) -> some View {
        var text = loc("home.network.header \(count)")
        if app.selectedPlanetId == app.activePlanetId && app.vpnRunning {
            let connected = app.networks.filter {
                $0.lastActivated && app.networkConflicts[$0.networkId] == nil
            }.count
            if connected > 1 {
                text += " · " + loc("home.network.connected \(connected)")
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

    private func networkCard(_ entry: NetworkEntry) -> some View {
        NetworkCardView(
            entry: entry,
            cardStatus: NetworkCardStatus(entry: entry, app: app),
            isPending: pendingNetworks.contains(entry.networkId),
            appearsActive: networkAppearsActive(entry),
            addresses: app.selectedPlanetId == app.activePlanetId
                ? app.networkConfigs[entry.networkId]?.assignedAddrs.map { String($0.split(separator: "/").first ?? Substring($0)) } : nil,
            onToggle: { setNetworkActive(entry, active: $0) },
            onTap: { path.append(.network(entry.networkId)) })
    }

    /// 非当前隧道 Planet 的网络统一显示为关闭，用户可直接打开以完成切换。
    private func networkAppearsActive(_ entry: NetworkEntry) -> Bool {
        app.selectedPlanetId == app.activePlanetId && entry.lastActivated
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
        // 软上限：新开网络会超出上限时先确认耗电（可强制开启）。
        let activeCount = app.networks.filter { $0.lastActivated && $0.networkId != entry.networkId }.count
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

    private func performNetworkActivate(_ entry: NetworkEntry) {
        var networks = app.networks
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
        AppConfigStore.writeNetworks(networks)
        app.reloadConfig()
        if routeViaTurnedOff {
            errorTitle = loc("home.error.multiNetworkTitle")
            errorAlert = loc("home.error.multiNetworkMessage")
        }

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
            errorTitle = loc("home.error.cellularTitle")
            errorAlert = loc("home.error.cellularMessage")
        }

        pendingNetworks.insert(entry.networkId)
        app.applySelectedPlanetAndStartVPN { ok, error in
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
