import Foundation

/// 以太网常量（帧本体不经过 ZTBridge——C API 语义为 MAC/ethertype 独立传参）
enum Ethernet {
    static let typeIPv4: UInt32 = 0x0800
    static let typeARP: UInt32 = 0x0806
    static let typeIPv6: UInt32 = 0x86DD
    static let broadcastMAC: UInt64 = 0xffffffffffff
}
