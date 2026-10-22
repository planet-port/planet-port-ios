import Foundation

// MARK: - 路由条目

/// IPv4 路由条目（地址均为 host order UInt32）
struct IPv4RouteEntry {
    let network: UInt32
    let prefix: Int
    /// via 网关（托管路由）；nil = 直连
    let gateway: UInt32?

    func matches(_ address: UInt32) -> Bool {
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << UInt32(32 - prefix)
        return address & mask == network & mask
    }
}

/// IPv6 路由条目（地址为 16 字节 Data）
struct IPv6RouteEntry {
    let network: Data
    let prefix: Int
    let gateway: Data?

    func matches(_ address: Data) -> Bool {
        guard network.count == 16, address.count == 16 else { return false }
        let fullBytes = prefix / 8
        guard network.prefix(fullBytes) == address.prefix(fullBytes) else { return false }
        let remaining = prefix % 8
        guard remaining > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remaining)
        return network[fullBytes] & mask == address[fullBytes] & mask
    }
}

// MARK: - 聚合表与冲突码

/// 聚合表条目：路由 + 归属网络（出站最长前缀匹配选网络）
struct AggregateV4Entry {
    let nwid: UInt64
    let route: IPv4RouteEntry
}

struct AggregateV6Entry {
    let nwid: UInt64
    let route: IPv6RouteEntry
}

/// 冲突原因原始码（跨进程契约：Extension 存原始码，中文文案在 App UI 层生成）
enum NetworkConflict: String {
    case address   // 两网络分配了相同 IP
    case subnet    // 两网络直连网段相同
}

// MARK: - 网络上下文

/// 单个网络在数据面的全部隔离状态（class：FrameConverter 字典内原位可变）。
/// MAC、地址、ARP/NDP、待决包、路由互不串网——多网络隔离的最小单元。
final class NetworkContext {
    let nwid: UInt64
    var mac: UInt64 = 0
    var ipv4Addresses: [UInt32] = []
    var ipv6Addresses: [Data] = []
    /// 直连（由分配地址网段展开）+ 托管路由，前缀降序
    var routesV4: [IPv4RouteEntry] = []
    var routesV6: [IPv6RouteEntry] = []
    var arp = ARPTable()
    var ndp = NDPTable()
    /// 等 ARP/NA 应答的包（追加侧有每下一跳上限，见 FrameConverter.maxPendingPerTarget）
    var pendingV4: [UInt32: [Data]] = [:]
    var pendingV6: [Data: [Data]] = [:]

    init(nwid: UInt64, mac: UInt64, ipv4Strings: [String], ipv6Strings: [String], routes: [String]) {
        self.nwid = nwid
        self.mac = mac
        ipv4Addresses = ipv4Strings.compactMap { FrameConverter.parseIPv4(NetworkContextMath.ipOnly($0)) }
        ipv6Addresses = ipv6Strings.compactMap { FrameConverter.parseIPv6Data(NetworkContextMath.ipOnly($0)) }
        routesV4 = (ipv4Strings.map { RoutePlanner.networkCIDR4($0) } + routes)
            .compactMap(NetworkContextMath.parseIPv4Route)
            .sorted { $0.prefix > $1.prefix }
        routesV6 = (ipv6Strings.map { RoutePlanner.networkCIDR6($0) } + routes)
            .compactMap(NetworkContextMath.parseIPv6Route)
            .sorted { $0.prefix > $1.prefix }
    }
}

// MARK: - 配置期纯逻辑

/// 路由解析、冲突检测（后进入者让路）、跨网络聚合表构建。
/// 与 FrameConverter（转发热路径）分离——配置回调走这里，包转发不碰解析。
enum NetworkContextMath {

    /// 冲突检测：输入按激活顺序。先到者登记已占 IP 与直连网段；
    /// 后进入者撞车标记冲突（地址冲突优先于网段冲突）且不登记先占。
    /// 冲突网络由调用方排除出数据面，保留 join 仅展示状态。
    static func detectConflicts(_ ordered: [(nwid: UInt64, ipv4: [String], ipv6: [String])]) -> [UInt64: NetworkConflict] {
        var claimedIP4 = Set<UInt32>()
        var claimedIP6 = Set<Data>()
        var claimedSubnets = Set<String>()
        var conflicts: [UInt64: NetworkConflict] = [:]
        for item in ordered {
            let subnets = item.ipv4.map { RoutePlanner.networkCIDR4($0) }
                + item.ipv6.map { RoutePlanner.networkCIDR6($0) }
            let conflict: NetworkConflict?
            if item.ipv4.compactMap({ FrameConverter.parseIPv4(NetworkContextMath.ipOnly($0)) }).contains(where: claimedIP4.contains)
                || item.ipv6.compactMap({ FrameConverter.parseIPv6Data(NetworkContextMath.ipOnly($0)) }).contains(where: claimedIP6.contains) {
                conflict = .address
            } else if subnets.contains(where: claimedSubnets.contains) {
                conflict = .subnet
            } else {
                conflict = nil
            }
            if let conflict {
                conflicts[item.nwid] = conflict
                continue
            }
            claimedIP4.formUnion(item.ipv4.compactMap { FrameConverter.parseIPv4(ipOnly($0)) })
            claimedIP6.formUnion(item.ipv6.compactMap { FrameConverter.parseIPv6Data(ipOnly($0)) })
            claimedSubnets.formUnion(subnets)
        }
        return conflicts
    }

    /// IPv4 聚合表：全部网络路由，前缀降序、同前缀按激活顺序（先到者胜）
    static func buildAggregateV4(_ orderedContexts: [NetworkContext]) -> [AggregateV4Entry] {
        let flat: [(prefix: Int, order: Int, entry: AggregateV4Entry)] = orderedContexts.enumerated()
            .flatMap { index, ctx in
                ctx.routesV4.map { (prefix: $0.prefix, order: index,
                                    entry: AggregateV4Entry(nwid: ctx.nwid, route: $0)) }
            }
        return flat
            .sorted { $0.prefix == $1.prefix ? $0.order < $1.order : $0.prefix > $1.prefix }
            .map(\.entry)
    }

    /// IPv6 聚合表：同 buildAggregateV4
    static func buildAggregateV6(_ orderedContexts: [NetworkContext]) -> [AggregateV6Entry] {
        let flat: [(prefix: Int, order: Int, entry: AggregateV6Entry)] = orderedContexts.enumerated()
            .flatMap { index, ctx in
                ctx.routesV6.map { (prefix: $0.prefix, order: index,
                                    entry: AggregateV6Entry(nwid: ctx.nwid, route: $0)) }
            }
        return flat
            .sorted { $0.prefix == $1.prefix ? $0.order < $1.order : $0.prefix > $1.prefix }
            .map(\.entry)
    }

    // MARK: 解析（自 FrameConverter 迁入，路由解析只此一份）

    static func ipOnly(_ cidr: String) -> String {
        String(cidr.split(separator: "/", maxSplits: 1).first ?? "")
    }

    /// "10.0.0.0/24" 或 "10.0.0.0/24 via 10.0.0.1" → IPv4RouteEntry
    static func parseIPv4Route(_ value: String) -> IPv4RouteEntry? {
        let fields = value.split(separator: " ").map(String.init)
        guard let target = fields.first else { return nil }
        let parts = target.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let address = FrameConverter.parseIPv4(String(parts[0])),
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
        let gatewayIndex = fields.firstIndex(of: "via").map { $0 + 1 }
        let gateway = gatewayIndex.flatMap { $0 < fields.count ? FrameConverter.parseIPv4(ipOnly(fields[$0])) : nil }
        return IPv4RouteEntry(network: address, prefix: prefix, gateway: gateway)
    }

    /// "fd00::/24" 或 "fd00::/24 via fd00::1" → IPv6RouteEntry
    static func parseIPv6Route(_ value: String) -> IPv6RouteEntry? {
        let fields = value.split(separator: " ").map(String.init)
        guard let target = fields.first else { return nil }
        let parts = target.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let address = FrameConverter.parseIPv6Data(String(parts[0])),
              let prefix = Int(parts[1]), prefix >= 0, prefix <= 128 else { return nil }
        let gatewayIndex = fields.firstIndex(of: "via").map { $0 + 1 }
        let gateway = gatewayIndex.flatMap { $0 < fields.count ? FrameConverter.parseIPv6Data(ipOnly(fields[$0])) : nil }
        return IPv6RouteEntry(network: address, prefix: prefix, gateway: gateway)
    }
}
