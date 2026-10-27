import Foundation

/// 单帧结构。text 即二维码内容：ZTQR1|total|index|crc32|len|chunk
/// total/index 为两位十进制（1..99，index 从 1 起），crc32 为原始数据的 CRC、
/// len 为 Base45 全长（真实字符数，每帧重复携带），均用于接收端自描述恢复。
public struct QRFrame: Equatable {
    let total: Int
    let index: Int
    let checksum: UInt32
    let length: Int
    /// Base45 分片字符串（末帧含补 '0' 对齐）
    let payload: String
}

public enum QRTransferError: Error, Equatable {
    case tooLarge
    case incomplete
    case corrupt
}
