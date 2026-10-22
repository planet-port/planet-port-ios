import Foundation
import NetworkExtension

/// 路由数学与网络接口探测（纯函数，无状态）：
/// 从 ZT 网络配置生成 NEPacketTunnelNetworkSettings 所需的路由集合，
/// 包含前缀差集（挖除物理 on-link 子网）、CIDR 换算与出口探测。
/// 从 PacketTunnelProvider 拆出——算法集中于此，便于独立阅读与验证。
enum RoutePlanner {

    // MARK: - 出口探测

    /// UDP connect 探测内核 v4 出口的源地址与接口：源 IP 用于 socket bind
    /// （固定源地址不改变路由查找，仍走 unscoped 默认路由——IP_BOUND_IF 的
    /// scoped 查找在 extension 环境会失败，已被对照实验否证）。
    static func probeOutboundV4() -> (ifName: String, ip: in_addr)? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("8.8.8.8"))
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(s, UnsafeMutablePointer(mutating: $0), &len) == 0
        } }), local.sin_family == sa_family_t(AF_INET) else { return nil }
        let sourceIP = local.sin_addr
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let ifa = p.pointee.ifa_addr, ifa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let sa = ifa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            if sa.sin_addr.s_addr == sourceIP.s_addr {
                return (String(cString: p.pointee.ifa_name), sourceIP)
            }
        }
        return nil
    }

    /// 是否物理业务接口（Wi-Fi/有线 en*、蜂窝 pdp_ip*；排除 lo/utun/awdl/bridge 等虚拟接口）
    private static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    /// 掩码字节 → 前缀长度（接口掩码必为连续 1）
    private static func prefixLength(ofMask mask: [UInt8]) -> UInt {
        UInt(mask.reduce(0) { $0 + (8 - $1.leadingZeroBitCount) })
    }

    // MARK: - 前缀差集（excludedRoutes 的替代方案）

    /// 网络序 IP 前缀。IPv4 用 4 字节，IPv6 用 16 字节。
    struct IPPrefix: Equatable {
        let bytes: [UInt8]
        let length: Int

        /// self ⊇ other（other 完全落在 self 网段内）
        func contains(_ other: IPPrefix) -> Bool {
            guard length <= other.length else { return false }
            for i in 0..<length where bit(i) != other.bit(i) { return false }
            return true
        }

        /// 一分为二（二叉前缀分解用）
        func split() -> (IPPrefix, IPPrefix) {
            let byteIndex = length / 8
            let mask = UInt8(1) << UInt8(7 - length % 8)
            var left = bytes
            var right = bytes
            left[byteIndex] &= ~mask
            right[byteIndex] |= mask
            return (IPPrefix(bytes: left, length: length + 1),
                    IPPrefix(bytes: right, length: length + 1))
        }

        private func bit(_ i: Int) -> Int {
            Int((bytes[i / 8] >> (7 - i % 8)) & 1)
        }
    }

    /// dest 挖除 hole → 剩余前缀列表（递归二分，同 WireGuard iOS 的做法）
    private static func subtract(_ dest: IPPrefix, _ hole: IPPrefix) -> [IPPrefix] {
        if dest == hole || hole.contains(dest) { return [] }
        guard dest.contains(hole) else { return [dest] }
        let (left, right) = dest.split()
        return subtract(left, hole) + subtract(right, hole)
    }

    /// 前缀长度 → 掩码字节（total = 4 或 16）
    private static func maskBytes(length: Int, total: Int) -> [UInt8] {
        (0..<total).map { i in
            let ones = max(0, min(8, length - i * 8))
            return ones == 0 ? 0 : UInt8.max << (8 - ones)
        }
    }

    private static func v6String(_ bytes: [UInt8]) -> String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return "::" }
        return String(cString: buf)
    }

    /// IPv4 CIDR（可带 "via 网关"）挖除若干前缀后展开为 includedRoutes
    static func expandV4(_ r: String, subtracting holes: [IPPrefix]) -> [NEIPv4Route] {
        let dest = String(r.split(separator: " ").first ?? Substring(r))
        guard let ip = FrameConverter.parseIPv4(ipOnly(dest)) else { return [route(dest)] }
        var result = [IPPrefix(
            bytes: [UInt8((ip >> 24) & 0xff), UInt8((ip >> 16) & 0xff),
                    UInt8((ip >> 8) & 0xff), UInt8(ip & 0xff)],
            length: Int(min(prefixLen(dest), 32)))]
        for hole in holes { result = result.flatMap { subtract($0, hole) } }
        return result.map {
            NEIPv4Route(destinationAddress: $0.bytes.map(String.init).joined(separator: "."),
                        subnetMask: maskBytes(length: $0.length, total: 4)
                            .map(String.init).joined(separator: "."))
        }
    }

    /// IPv6 CIDR（可带 "via 网关"）挖除若干前缀后展开为 includedRoutes
    static func expandV6(_ r: String, subtracting holes: [IPPrefix]) -> [NEIPv6Route] {
        let dest = String(r.split(separator: " ").first ?? Substring(r))
        var addr = in6_addr()
        guard inet_pton(AF_INET6, ipOnly(dest), &addr) == 1 else { return [route6(dest)] }
        var result = [IPPrefix(bytes: withUnsafeBytes(of: addr) { Array($0) },
                               length: Int(min(prefixLen(dest), 128)))]
        for hole in holes { result = result.flatMap { subtract($0, hole) } }
        return result.map {
            NEIPv6Route(destinationAddress: v6String($0.bytes),
                        networkPrefixLength: $0.length as NSNumber)
        }
    }

    /// 物理接口 on-link IPv4 子网 → 待挖除前缀集合。
    /// ZT managed routes（如 192.168.0.0/16）会覆盖本机物理局域网，把本地网关/DNS
    /// 的流量抓进隧道黑洞；从隧道路由中挖除后本地子网仍走物理网卡。
    /// excludingNetworksOf：子网与 ZT 分配地址所在网段相同时跳过，避免反过来打断 ZeroTier。
    static func physicalOnLinkPrefixes4(excludingNetworksOf assigned: [String]) -> [IPPrefix] {
        let assignedNetworks = Set(assigned.map { networkCIDR4($0) })
        var seen = Set<String>()
        var prefixes: [IPPrefix] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard isPhysicalInterface(String(cString: p.pointee.ifa_name)) else { continue }
            guard let addrPtr = p.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = p.pointee.ifa_netmask else { continue }
            let addrBytes = addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0.prefix(4)) }
            }
            let maskBytes = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0.prefix(4)) }
            }
            let network = zip(addrBytes, maskBytes).map { $0 & $1 }
            let prefix = prefixLength(ofMask: maskBytes)
            let cidr = "\(network.map(String.init).joined(separator: "."))/\(prefix)"
            guard !seen.contains(cidr), !assignedNetworks.contains(cidr) else { continue }
            seen.insert(cidr)
            prefixes.append(IPPrefix(bytes: network, length: Int(prefix)))
        }
        return prefixes
    }

    /// 物理接口 on-link IPv6 子网 → 待挖除前缀集合（跳过 fe80:: 链路本地，本就不会经默认路由）。
    static func physicalOnLinkPrefixes6(excludingNetworksOf assigned: [String]) -> [IPPrefix] {
        let assignedNetworks = Set(assigned.map { networkCIDR6($0) })
        var seen = Set<String>()
        var prefixes: [IPPrefix] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard isPhysicalInterface(String(cString: p.pointee.ifa_name)) else { continue }
            guard let addrPtr = p.pointee.ifa_addr, addrPtr.pointee.sa_family == sa_family_t(AF_INET6),
                  let maskPtr = p.pointee.ifa_netmask else { continue }
            let addrBytes = addrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(16)) }
            }
            guard !addrBytes.starts(with: [0xfe, 0x80]) else { continue }
            let maskBytes = maskPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0.prefix(16)) }
            }
            let networkBytes = zip(addrBytes, maskBytes).map { $0 & $1 }
            let prefix = prefixLength(ofMask: maskBytes)
            let cidr = "\(v6String(networkBytes))/\(prefix)"
            guard !seen.contains(cidr), !assignedNetworks.contains(cidr) else { continue }
            seen.insert(cidr)
            prefixes.append(IPPrefix(bytes: networkBytes, length: Int(prefix)))
        }
        return prefixes
    }

    // MARK: - CIDR 换算

    /// "10.0.0.1/24" → "10.0.0.1"
    static func ipOnly(_ cidr: String) -> String {
        String(cidr.split(separator: "/").first ?? "")
    }

    /// "10.0.0.1/24" → "255.255.255.0"
    static func subnetMask(_ cidr: String) -> String {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = UInt32(parts[1]), prefix <= 32 else { return "255.255.255.0" }
        let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return String(format: "%d.%d.%d.%d",
                      (mask >> 24) & 0xff, (mask >> 16) & 0xff, (mask >> 8) & 0xff, mask & 0xff)
    }

    /// "10.0.0.0/24" 或 "10.0.0.0/24 via 10.0.0.1" → NEIPv4Route
    static func route(_ r: String) -> NEIPv4Route {
        let parts = r.split(separator: " ")
        let dest = parts.first.map { String($0) } ?? r
        return NEIPv4Route(destinationAddress: ipOnly(dest),
                           subnetMask: subnetMask(dest))
    }

    static func route6(_ r: String) -> NEIPv6Route {
        let parts = r.split(separator: " ")
        let dest = parts.first.map { String($0) } ?? r
        return NEIPv6Route(destinationAddress: ipOnly(dest),
                           networkPrefixLength: prefixLen(dest) as NSNumber)
    }

    static func isDefaultRoute(_ route: String) -> Bool {
        let destination = route.split(separator: " ").first.map(String.init) ?? route
        return destination == "0.0.0.0/0" || destination == "::/0"
    }

    /// "fd00::/24" → 24
    static func prefixLen(_ cidr: String) -> UInt {
        let parts = cidr.split(separator: "/")
        return parts.count == 2 ? UInt(parts[1]) ?? 64 : 64
    }

    static func networkCIDR4(_ cidr: String) -> String {
        let prefix = min(prefixLen(cidr), 32)
        guard let ip = FrameConverter.parseIPv4(ipOnly(cidr)) else { return cidr }
        let mask = prefix == 0 ? UInt32(0) : UInt32.max << (32 - UInt32(prefix))
        let network = ip & mask
        return String(format: "%u.%u.%u.%u/%u",
                      (network >> 24) & 0xff, (network >> 16) & 0xff,
                      (network >> 8) & 0xff, network & 0xff, prefix)
    }

    static func networkCIDR6(_ cidr: String) -> String {
        let prefix = min(prefixLen(cidr), 128)
        var address = in6_addr()
        guard inet_pton(AF_INET6, ipOnly(cidr), &address) == 1 else { return cidr }
        var bytes = withUnsafeBytes(of: &address) { Array($0) }
        for bit in Int(prefix)..<128 {
            bytes[bit / 8] &= ~(UInt8(1) << UInt8(7 - bit % 8))
        }
        var network = in6_addr()
        withUnsafeMutableBytes(of: &network) { raw in
            raw.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &network, &buffer, socklen_t(buffer.count)) != nil else { return cidr }
        return "\(String(cString: buffer))/\(prefix)"
    }
}
