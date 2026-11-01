import Foundation
import os

/// 节点身份模式的存取与身份文件操作（App 侧管理；Extension 侧经
/// ZTBridge ztHookedPath 按同一模式偏好重定向读写，见 AppGroup.prefIdentityPerPlanet）。
/// 共享身份：datastore/identity.*（全行星共用，默认）；
/// 每行星身份：planet-state/<id>/identity.*（核心首次在该行星以独立模式启动时
/// 自行生成；目录随删除行星级联清理，见 AppConfigStore.deletePlanet）。
enum IdentityStore {
    private static let log = Logger(subsystem: "cn.imgozi.i.PlanetPort", category: "IdentityStore")
    static let identityPublicName = "identity.public"
    static let identitySecretName = "identity.secret"

    /// 是否每行星独立身份（默认 false = 共享）。
    static var perPlanet: Bool {
        get { AppGroup.defaults.bool(forKey: AppGroup.prefIdentityPerPlanet) }
        set { AppGroup.defaults.set(newValue, forKey: AppGroup.prefIdentityPerPlanet) }
    }

    /// 每行星身份文件 URL（planet-state/<id>/identity.*）。
    static func planetIdentityURL(_ planetId: String, secret: Bool = false) -> URL {
        AppGroup.planetStateDir(planetId)
            .appendingPathComponent(secret ? identitySecretName : identityPublicName)
    }

    /// 该行星是否已生成独立身份（以私钥文件为准）。
    static func hasPlanetIdentity(_ planetId: String) -> Bool {
        FileManager.default.fileExists(atPath: planetIdentityURL(planetId, secret: true).path)
    }

    /// 解析 identity.public 的节点地址：内容为 "address:publicKey"，
    /// 冒号前 10 位 hex 即 ZeroTier 节点地址。
    static func planetIdentityAddress(_ planetId: String) -> String? {
        guard let text = try? String(contentsOf: planetIdentityURL(planetId), encoding: .utf8),
              let address = text.split(separator: ":").first, address.count == 10 else { return nil }
        return String(address)
    }

    /// 播种：把当前共享身份复制为指定行星的独立身份（已有独立身份或共享身份
    /// 缺失时不动作）。切独立模式时让当前激活行星沿用现有身份，网络不中断。
    static func seedSharedIdentity(to planetId: String) {
        guard !hasPlanetIdentity(planetId) else { return }
        copyIdentity(from: AppGroup.datastore, to: AppGroup.planetStateDir(planetId))
    }

    /// 采纳：把指定行星的独立身份复制为全局共享身份（覆盖原共享身份文件）。
    /// 其余行星的独立身份文件原地保留，切回独立模式时原样恢复。
    static func adoptSharedIdentity(from planetId: String) {
        copyIdentity(from: AppGroup.planetStateDir(planetId), to: AppGroup.datastore)
    }

    /// 成对复制身份文件（源缺失跳过；目标已存在先移除再复制——seed 场景由
    /// hasPlanetIdentity 挡，adopt 场景覆盖即语义）。私钥保持 0600。
    private static func copyIdentity(from source: URL, to destination: URL) {
        let fm = FileManager.default
        for name in [identityPublicName, identitySecretName] {
            let src = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                log.error("身份文件复制失败 \(src.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            if name == identitySecretName {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
            }
        }
    }
}
