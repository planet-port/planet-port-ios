import Foundation

struct ProviderRequest: Codable {
    var type: String              // "peers" | "status" | "networkConfig"
    var nwid: String?
}

struct PeerEntry: Codable, Identifiable {
    var id: String { address }
    var address: String    // 10 位 hex
    var role: String       // planet / moon / leaf
    var version: String
    var latency: Int       // ms，-1 未知
    var path: String       // 物理路径，空为 relay
}

struct ProviderReply: Codable {
    var peers: [PeerEntry]?
    var nodeId: String?
    var online: Bool?
    var coreVersion: String?
    var networkConfig: NetworkConfigSnapshot?
}

struct NetworkConfigSnapshot: Codable, Equatable {
    var nwid: String
    var name: String
    var status: String
    var type: String
    var mac: String
    var mtu: Int
    var broadcastEnabled: Bool
    var bridge: Bool
    var assignedAddrs: [String]
    var routes: [String]
    var dns: [String]
}
