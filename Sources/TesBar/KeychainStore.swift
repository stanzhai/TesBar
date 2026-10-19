import Foundation
import Security

/// 凭证存取：access/refresh token → 本地 0600 文件（VCP 私钥已改为构建内置，ADR-0004）。
///
/// 为什么不用 Keychain：app 以 adhoc 签名分发，每次重打包 CDHash 都变，
/// 条目 ACL 记录的是创建时那个二进制 → 之后每次读都弹“钥匙串访问”授权框
/// （输登录密码）。Developer ID 签名前，Keychain 对这类 app 不可用。
/// 文件方案：`~/Library/Application Support/<service>/` 目录 0700、文件 0600，
/// 本机其他用户的进程读不到；同用户进程与读二进制内嵌的 client secret 门槛相同。
public enum KeychainError: Error, Equatable {
    case unhandled(OSStatus)
    case itemNotFound
}

public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.tesbar.app") {
        self.service = service
    }

    // MARK: Token

    public func saveToken(_ token: String, for account: String) throws {
        try setData(Data(token.utf8), account: account)
    }

    public func readToken(_ account: String) throws -> String {
        guard let data = try data(account: account),
              let token = String(data: data, encoding: .utf8)
        else { throw KeychainError.itemNotFound }
        return token
    }

    public func deleteToken(_ account: String) throws {
        try? FileManager.default.removeItem(at: url(account: account))
        // 旧版本可能还留有 Keychain 条目；顺手清掉（不存在则忽略）。
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }

    /// Presence check without throwing (UI uses this to decide guidance).
    public func hasToken(_ account: String) -> Bool {
        (try? data(account: account)) != nil
    }

    // MARK: File storage

    private func url(account: String) -> URL {
        directory().appendingPathComponent(account.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? account)
    }

    private func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(service, isDirectory: true)
    }

    private func setData(_ data: Data, account: String) throws {
        let dir = directory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = url(account: account)
        try data.write(to: file, options: .atomic)
        // Data.write 的 attributes 只在新建时生效，atomic 覆盖写可能保留旧模式；显式收紧。
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func data(account: String) throws -> Data? {
        let fileURL = url(account: account)
        guard let data = try? Data(contentsOf: fileURL) else {
            // 一次性迁移：Keychain 时代的旧条目 → 文件（读取可能弹最后一次授权框，
            // 用户点“始终允许”或拒绝都行；拒绝则视为无 token，走重登）。
            var query = legacyQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                let old = result as? Data
                if let old { try? setData(old, account: account) }
                SecItemDelete(query as CFDictionary)
                return old
            case errSecItemNotFound:
                return nil
            case let status:
                throw KeychainError.unhandled(status)
            }
        }
        return data
    }

    private func legacyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
