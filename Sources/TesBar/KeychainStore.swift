import Foundation
import Security

/// 凭证存取：access/refresh token 与 VCP 私钥（PEM 字节）→ Keychain。
public enum KeychainError: Error, Equatable {
    case unhandled(OSStatus)
    case itemNotFound
}

public struct KeychainStore: Sendable {
    private let service: String
    private let privateKeyAccount: String

    public init(service: String = "com.tesbar.app", privateKeyAccount: String = "vcp-private-key") {
        self.service = service
        self.privateKeyAccount = privateKeyAccount
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
        try deleteData(account: account)
    }

    // MARK: VCP private key

    public func savePrivateKey(_ pem: Data) throws {
        try setData(pem, account: privateKeyAccount)
    }

    public func readPrivateKey() throws -> Data {
        guard let data = try data(account: privateKeyAccount) else {
            throw KeychainError.itemNotFound
        }
        return data
    }

    public func deletePrivateKey() throws {
        try deleteData(account: privateKeyAccount)
    }

    // MARK: SecItem CRUD

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func setData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unhandled(status)
        }
    }

    private func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandled(status)
        }
    }
}
