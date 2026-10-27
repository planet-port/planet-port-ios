import Foundation

/// 模块内本地化：表名 QRTransfer，bundle 定位到本模块目录。
/// 编进 App 或未来打成 pod（resource_bundles）两种形态都生效。
private final class QRTransferBundleLocator {}

extension Bundle {
    static var qrTransfer: Bundle { Bundle(for: QRTransferBundleLocator.self) }
}

/// 取模块文案。返回 String（已解析），配 Text(String) 或 String(format:) 使用。
func ql(_ key: String) -> String {
    NSLocalizedString(key, tableName: "QRTransfer", bundle: .qrTransfer,
                      value: key, comment: "")
}
