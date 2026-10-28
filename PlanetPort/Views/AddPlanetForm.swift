import SwiftUI
import UniformTypeIdentifiers

/// 内嵌在首页网络列表位置的添加 Planet 表单（右划到末位占位页时显示）。
/// 卡片预览与表单实时同步；文件/URL 先就绪，再点"添加"落库。
struct AddPlanetForm: View {
    /// 与首页 Pager 的预览卡片共享的名称(编辑已移至预览身份区,此处只读)。
    @Binding var name: String
    /// 身份(与首页 Pager 的预览卡片共享,添加时随名称一并落库;扫码导入可直接回填)。
    @Binding var animal: String
    @Binding var colorHex: String
    /// 是否停在本页（HomeView pagerSelection 同源）：离开计时，超时清空表单。
    var isCurrentPage: Bool = true
    /// 扫码预填成功时通知父级（父级据此豁免滑页重掷身份）。
    /// 声明在 onImported 之前：memberwise init 参数随声明序，调用处才能
    /// 以 onPrefill 标签 + 尾随闭包（onImported）的形式书写。
    var onPrefill: (() -> Void)? = nil
    let onImported: (PlanetProfile) -> Void

    @ObservedObject private var theme = ThemeManager.shared
    @State private var url = ""
    @State private var showFilePicker = false
    @State private var showScanner = false
    @State private var showPlanetReceiver = false
    @State private var downloading = false
    /// 下载进度 0~1；服务器未给 Content-Length 时为 nil（不确定进度）
    @State private var downloadProgress: Double?
    /// 下载/验证失败轻提示（toast）：overlay 展示不受 sheet 收起竞争影响
    @State private var toast: String?
    /// 已就绪、等待"添加"的 Planet 文件内容。
    @State private var pendingData: Data?
    @State private var alert: String?
    /// 离开新增页的时间；离开超过 5 分钟后回来视为放弃，清空表单。
    @State private var leftAt: Date?

    private static let keepFormInterval: TimeInterval = 5 * 60

    var body: some View {
        VStack(spacing: 16) {
            formCard
            addButton
        }
        // 下载/验证失败 toast：顶部胶囊，自动消失
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
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
        .alert("addplanet.importFailed", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } })) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(alert ?? "")
            }
        // 下载中模态锁定：sheet 挡住底下全部交互（含首页 Pager 滑页），
        // 禁下滑手势关闭，防止误操作提前退出
        .sheet(isPresented: $downloading) {
            VStack(spacing: 16) {
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                }
                Text("addplanet.downloading")
                    .font(.subheadline.weight(.medium))
                Text(url)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .presentationDetents([.height(180)])
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView(extract: QRScannerView.extractHttpUrl) { scanned in
                // 关扫码层 → 回填 URL → 直接下载导入。
                showScanner = false
                url = scanned
                importFromURL()
            }
        }
        .sheet(isPresented: $showPlanetReceiver) {
            QRReceiveView { data in
                showPlanetReceiver = false
                // 解析 ZTP 容器；非法容器（magic/边界不成立、缺 planet 字段）
                // 或旧版裸 planet 载荷都走统一"数据无效"提示。
                guard let payload = PlanetPayload.parse(data) else {
                    alert = loc("addplanet.qrInvalid")
                    return
                }
                do {
                    try validate(payload.planet)
                    pendingData = payload.planet
                    if let name = payload.name, !name.isEmpty { self.name = name }
                    if let icon = payload.icon { animal = icon }
                    if let iconColor = payload.iconColor { colorHex = iconColor }
                    onPrefill?()
                } catch {
                    alert = error.localizedDescription
                }
            }
        }
        .onChange(of: isCurrentPage) { current in
            if current {
                // 回来时才判断：离开超过 5 分钟清空 URL 与已就绪文件
                // （时间戳判墙钟，App 挂起期间同样计时）。
                if let leftAt,
                   Date().timeIntervalSince(leftAt) > Self.keepFormInterval {
                    url = ""
                    pendingData = nil
                }
                self.leftAt = nil
            } else {
                leftAt = Date()
            }
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

            // 选择文件独占一行：padding/背景放进 label，整块组件（含背景）都是点击热区。
            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Label("addplanet.chooseFile", systemImage: "doc")
                    Spacer()
                    if let data = pendingData {
                        Text("addplanet.ready \(locFileSize(data.count))")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.success)
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

            // 动态二维码导入（模块 QRTransfer）：连续扫分片，收齐即回填 pendingData，
            // 复用与文件/URL 相同的"命名 + 添加 + 查重"后续流程。
            Button {
                showPlanetReceiver = true
            } label: {
                Label("addplanet.scanPlanetQr", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(downloading)

            // 扫码导入：与"导入"按钮同款视觉，扫到 http(s) 链接后回填并直接下载。
            Button {
                showScanner = true
            } label: {
                Label("addplanet.scanUrl", systemImage: "qrcode")
                    // 字体与"选择行星文件"行一致：默认 .body 常规字重字号。
                    // 左对齐 + 12 水平内距：与"选择行星文件"行的文字起点一致。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .frame(height: 42)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(downloading)

            // URL：输入框左，导入按钮右（按钮高度与输入框一致）
            HStack(spacing: 10) {
                field($url, placeholder: loc("addplanet.urlPlaceholder"), keyboard: .URL)
                Button {
                    importFromURL()
                } label: {
                    Group {
                        if downloading {
                            ProgressView()
                        } else {
                            Text("common.import")
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
            Text("addplanet.action")
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
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.subheadline)
                .foregroundStyle(.primary)
            TextField(placeholder, text: binding)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
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
            alert = loc("addplanet.duplicate \(String(format: "%016llx", worldId))")
            return
        }
        do {
            let profile = try PlanetImporter.importPlanetData(data, name: trimmedName,
                                                              icon: animal, iconColor: colorHex)
            pendingData = nil
            url = ""
            onImported(profile)
        } catch {
            alert = error.localizedDescription
        }
    }

    private func importFromURL() {
        downloading = true
        downloadProgress = nil
        PlanetImporter.downloadPlanetFile(url, progress: { fraction in
            Task { @MainActor in downloadProgress = fraction }
        }) { result in
            Task { @MainActor in
                downloading = false
                switch result {
                case .success(let data):
                    do {
                        try validate(data)
                        pendingData = data
                    } catch {
                        withAnimation { toast = error.localizedDescription }
                    }
                case .failure(let error):
                    withAnimation { toast = error.localizedDescription }
                }
            }
        }
    }
}
