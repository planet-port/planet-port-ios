import Foundation

/// 每帧容量探测：二分查找最大的"分片字符数"，
/// 使 定长协议头+该长度探测串 生成的二维码模块数 ≤ maxModules。
/// 探测串与真实分片同为 ASCII 且等长，编码行为一致，单调可二分。
enum ChunkPlanner {
    static func capacity(payloadCount: Int, headerLen: Int, maxModules: Int) -> Int? {
        var lo = 1
        var hi = max(payloadCount, 1)
        var best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let probe = String(repeating: "0", count: headerLen + mid)
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
