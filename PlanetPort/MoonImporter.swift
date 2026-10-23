import Foundation
import UniformTypeIdentifiers

/// Moon 文件导入
enum MoonImporter {
    enum ImportError: LocalizedError {
        case badHeader
        case readFailed

        var errorDescription: String? {
            switch self {
            case .badHeader: return loc("error.moon.badHeader")
            case .readFailed: return loc("error.moon.readFailed")
            }
        }
    }

    /// 校验 .moon 文件并落盘当前 Planet 独立的 moons.d 目录。
    /// 文件格式：首字节 0x7f + 8 字节大端 worldId
    static func importMoonFile(at url: URL) throws -> MoonEntry {
        let accessing = url.startAccessingSecurityScopedResource
        let scoped = accessing()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url), data.count >= 9 else {
            throw ImportError.readFailed
        }
        guard data[0] == 0x7f else {
            throw ImportError.badHeader
        }
        var worldId: UInt64 = 0
        for i in 1...8 {
            worldId = (worldId << 8) | UInt64(data[i])
        }

        let planetId = AppConfigStore.selectedPlanetId
        let dest = AppGroup.planetStateDir(planetId)
            .appendingPathComponent("moons.d", isDirectory: true)
            .appendingPathComponent(String(format: "%016llx.moon", worldId))
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        return MoonEntry(worldId: worldId, seed: 0, fromFile: true, planetId: planetId)
    }
}
