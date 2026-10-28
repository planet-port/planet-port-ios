import Foundation

/// ZTP 容器的 PlanetPort 应用层 key 约定（key 语义归应用层，组件零假设）：
/// 1=planet 二进制(必备) 2=名称 3=图标 key 4=图标底色 hex。
enum PlanetPayload {
    static let keyPlanet: UInt8 = 1
    static let keyName: UInt8 = 2
    static let keyIcon: UInt8 = 3
    static let keyIconColor: UInt8 = 4

    struct SharePayload: Equatable {
        let planet: Data
        let name: String?
        let icon: String?
        let iconColor: String?
    }

    /// 组容器：名称必带（空名防御性省略）；icon/iconColor 为 nil 时省略条目。
    static func container(planet: Data, name: String, icon: String?, iconColor: String?) -> Data {
        var fields: [(key: UInt8, value: Data)] = [(keyPlanet, planet)]
        if !name.isEmpty { fields.append((keyName, Data(name.utf8))) }
        if let icon { fields.append((keyIcon, Data(icon.utf8))) }
        if let iconColor { fields.append((keyIconColor, Data(iconColor.utf8))) }
        return PayloadContainer.encode(fields)
    }

    /// 解析容器。容器非法（magic/边界不成立）或 planet 字段缺失 → nil。
    /// 文本字段按 UTF-8 解码，失败按缺省处理（保留 planet 可用性）。
    static func parse(_ data: Data) -> SharePayload? {
        guard let fields = PayloadContainer.decode(data),
              let planet = fields[keyPlanet] else { return nil }
        func text(_ key: UInt8) -> String? {
            fields[key].flatMap { String(data: $0, encoding: .utf8) }
        }
        return SharePayload(planet: planet, name: text(keyName),
                            icon: text(keyIcon), iconColor: text(keyIconColor))
    }
}
