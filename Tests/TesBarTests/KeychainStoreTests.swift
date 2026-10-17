import Foundation
import Security
import Testing

@testable import TesBar

/// 真 Keychain 集成测试（ticket 02 记载的例外）。
/// 账户名带 UUID 后缀，测试结束删除，保证重跑全绿。
struct KeychainStoreTests {
    /// Isolated service like every other suite: the default `com.tesbar.app`
    /// namespace holds real app items whose ACL blocks test binaries (prompt /
    /// hang in headless runs once the app has created its key).
    let store = KeychainStore(service: "KeychainStoreTests-\(UUID().uuidString)")
    let run = UUID().uuidString

    @Test func saveReadRoundTrip() throws {
        try store.saveToken("token-\(run)", for: "access-\(run)")
        #expect(try store.readToken("access-\(run)") == "token-\(run)")
        defer { try? store.deleteToken("access-\(run)") }

        try store.savePrivateKey(Data("pem-\(run)".utf8))
        #expect(try store.readPrivateKey() == Data("pem-\(run)".utf8))
        try store.deletePrivateKey()
        #expect(throws: KeychainError.itemNotFound) { try store.readPrivateKey() }
    }

    @Test func deleteThenReadFails() throws {
        try store.saveToken("t", for: "refresh-\(run)")
        try store.deleteToken("refresh-\(run)")
        #expect(throws: KeychainError.itemNotFound) { try store.readToken("refresh-\(run)") }
    }

    @Test func readMissingKeyFailsTyped() {
        #expect(throws: KeychainError.itemNotFound) { try store.readToken("missing-\(run)") }
    }

    @Test func saveOverwritesExisting() throws {
        defer { try? store.deleteToken("access-\(run)") }
        try store.saveToken("old", for: "access-\(run)")
        try store.saveToken("new", for: "access-\(run)")
        #expect(try store.readToken("access-\(run)") == "new")
    }

    @Test func readsOffMainThread() async throws {
        // KeychainStore 须可在非主线程 caller 下使用（无宿主 App 的测试环境）。
        let store = self.store, run = self.run
        try await Task.detached {
            try store.saveToken("bg-\(run)", for: "bg-\(run)")
            #expect(try store.readToken("bg-\(run)") == "bg-\(run)")
            try store.deleteToken("bg-\(run)")
        }.value
    }
}
