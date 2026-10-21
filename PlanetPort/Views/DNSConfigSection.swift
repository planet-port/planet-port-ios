import SwiftUI

/// DNS 配置编辑状态（加入网络 / 网络详情共用）。
/// 四槽位模型对齐 Android CustomDNSFragment（v4×2 + v6×2），持久化时合并为 [String]。
struct DNSConfig: Equatable {
    var mode: DNSMode = .none
    var v4a = ""
    var v4b = ""
    var v6a = ""
    var v6b = ""

    /// 从持久化的 NetworkEntry 构造（v4/v6 按是否含 ":" 区分）。
    init(mode: DNSMode = .none, customDns: [String] = []) {
        self.mode = mode
        let v4 = customDns.filter { !$0.contains(":") }
        let v6 = customDns.filter { $0.contains(":") }
        v4a = v4.first ?? ""
        v4b = v4.count > 1 ? v4[1] : ""
        v6a = v6.first ?? ""
        v6b = v6.count > 1 ? v6[1] : ""
    }

    /// 自定义模式下要保存的服务器列表（空槽位丢弃，顺序 v4 在前）。
    var customServers: [String] {
        [v4a, v4b, v6a, v6b].filter { !$0.isEmpty }
    }

    var isValid: Bool {
        guard mode == .custom else { return true }
        return [v4a, v4b].allSatisfy(Self.isValidIPv4OrEmpty)
            && [v6a, v6b].allSatisfy(Self.isValidIPv6OrEmpty)
            && !customServers.isEmpty
    }

    // MARK: - 校验（对齐 Android CustomDNSFragment 的 IP 校验）

    private static func isValidIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private static func isValidIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return s.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static let isValidIPv4OrEmpty: (String) -> Bool = { $0.isEmpty || isValidIPv4($0) }
    private static let isValidIPv6OrEmpty: (String) -> Bool = { $0.isEmpty || isValidIPv6($0) }
}

/// DNS 配置编辑区（模式分段选择 + 自定义服务器四槽位），加入网络 sheet 与
/// 网络详情页共用同一布局。
struct DNSConfigSection: View {
    @Binding var config: DNSConfig

    var body: some View {
        Picker("模式", selection: $config.mode) {
            Text("不使用").tag(DNSMode.none)
            Text("使用网络 DNS").tag(DNSMode.network)
            Text("自定义").tag(DNSMode.custom)
        }
        .pickerStyle(.segmented)
        if config.mode == .custom {
            TextField("IPv4 DNS 1", text: $config.v4a)
                .keyboardType(.decimalPad)
            TextField("IPv4 DNS 2（可选）", text: $config.v4b)
                .keyboardType(.decimalPad)
            TextField("IPv6 DNS 1", text: $config.v6a)
            TextField("IPv6 DNS 2（可选）", text: $config.v6b)
            if !config.isValid {
                Text("DNS 地址格式不正确")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
