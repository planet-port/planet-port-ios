import Foundation

/// 每帧容量探测：二分查找最大的"分片字符数"，
/// 使 真实形态定长头+该长度探测串 生成的二维码模块数 ≤ maxModules。
/// 探测串必须携带真实帧头（含 '|'，byte mode）：纯 "0" 会走 numeric mode
/// （3.33 bit/字符），导致容量高估近一倍。
enum ChunkPlanner {
    /// 与真实帧头等形等长（count == QRTransfer.headerLen == 27）
    /// internal 而非 private：QRTransferFrameTests 需断言两者长度一致（帧格式失配防护）
    static let probePrefix = "ZTQR1|99|99|ffffffff|00000|"

    static func capacity(payloadCount: Int, headerLen: Int, maxModules: Int) -> Int? {
        var lo = 1
        var hi = max(payloadCount, 1)
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            // 尾部用小写 'z' 填充：裸数字会被编码器切 numeric segment 再次低估，
            // 非字母数字字符强制 byte mode（8 bit/字符）即最坏情况上界，
            // 真实分片的任何分段优化只会比探测更省模块
            let probe = probePrefix + String(repeating: "z", count: mid)
            if QRRender.fits(probe, maxModules: maxModules) {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }
}
