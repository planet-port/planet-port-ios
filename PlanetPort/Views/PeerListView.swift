import SwiftUI

/// Peers 列表（对齐 Android PeerListFragment：下拉刷新、无定时器）。
/// 视觉与首页卡片语言统一：透明行 + 灰底圆角卡；延迟按 好/一般/差 语义着色，
/// 中转连接用橙色胶囊标识，查询/隧道未运行/空三种状态复用空态卡。
struct PeerListView: View {
    @EnvironmentObject private var app: AppState
    @State private var peers: [PeerEntry] = []
    @State private var loaded = false

    var body: some View {
        List {
            if peers.isEmpty {
                statusCard
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.cardInsets)
                    .listRowBackground(Color.clear)
            }
            ForEach(peers) { peer in
                peerCard(peer)
                    .listRowSeparator(.hidden)
                    .listRowInsets(Self.cardInsets)
                    .listRowBackground(Color.clear)
            }
        }
        // 去掉系统分组底，页面底色与首页一致。
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Peers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .refreshable { refresh() }
    }

    /// 与首页一致的卡片行边距（水平 20 对齐页面边距，卡间留 12 视觉间隙）。
    private static let cardInsets = EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20)

    // MARK: - 状态卡（查询中 / 隧道未运行 / 空）

    private var statusCard: some View {
        VStack(spacing: 10) {
            if !loaded {
                ProgressView()
                Text("正在查询 Peers…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            } else if !app.vpnRunning {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("隧道未运行")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("开启网络后可查看实时连接")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "person.2")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("“\(app.activePlanet.name)”暂无 Peers")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("下拉刷新重试")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Peer 卡

    private func peerCard(_ peer: PeerEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(peer.address)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                roleBadge(peer.role)
            }
            HStack(spacing: 8) {
                Text("v\(peer.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if peer.latency >= 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(latencyColor(peer.latency))
                            .frame(width: 6, height: 6)
                        Text("\(peer.latency) ms")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(latencyColor(peer.latency))
                    }
                }
            }
            if peer.path.isEmpty {
                // 无直连路径 = 经 planet/root 中转，是性能劣化信号，橙色标识。
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                    Text("中转 relay")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.12), in: Capsule())
            } else {
                Text(peer.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func roleBadge(_ role: String) -> some View {
        Text(role.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
    }

    /// 延迟语义色：<30ms 好 / <100ms 一般 / ≥100ms 差。
    private func latencyColor(_ ms: Int) -> Color {
        if ms < 30 { return .green }
        if ms < 100 { return .orange }
        return .red
    }

    private func refresh() {
        VPNManager.shared.query(ProviderRequest(type: "peers", nwid: nil)) { reply in
            Task { @MainActor in
                peers = reply?.peers ?? []
                loaded = true
            }
        }
    }
}
