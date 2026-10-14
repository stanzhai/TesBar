import Foundation
import Security
import Testing

@testable import TesBar

/// 真 Keychain 集成测试（ticket 03/02 记载的例外）。
/// 每个用例用 UUID service/account 隔离，defer 清理，保证重跑全绿。
struct VCPKeyManagerTests {
    private func makeManager() -> (VCPKeyManager, KeychainStore) {
        let run = UUID().uuidString
        let store = KeychainStore(service: "com.tesbar.test.\(run)", privateKeyAccount: "vcp-\(run)")
        return (VCPKeyManager(store: store), store)
    }

    @Test func firstCallGeneratesSecondCallSamePEM() throws {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }

        let first = try mgr.ensureKeyPair()
        #expect(first.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        #expect(first.contains("-----END PUBLIC KEY-----"))

        let second = try mgr.ensureKeyPair()
        #expect(second == first)
    }

    @Test func storedPrivateKeyPEMIsSEC1() throws {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }

        _ = try mgr.ensureKeyPair()
        let pem = String(decoding: try store.readPrivateKey(), as: UTF8.self)
        #expect(pem.hasPrefix("-----BEGIN EC PRIVATE KEY-----"))
        #expect(pem.contains("-----END EC PRIVATE KEY-----"))
    }

    @Test func loadPrivateKeyRebuildsAndDerivesSamePublicKey() throws {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }

        let pubPEM = try mgr.ensureKeyPair()
        let priv = try mgr.loadPrivateKey()
        let rebuilt = mgr.publicPEM(SecKeyCopyPublicKey(priv)!)
        #expect(rebuilt == pubPEM)
    }

    @Test func publicPEMRebuildsViaSecKeyCreateWithData() throws {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }

        let pubPEM = try mgr.ensureKeyPair()
        let pub = try mgr.secKey(fromPublicPEM: pubPEM)
        #expect(mgr.publicPEM(pub) == pubPEM)
    }

    @Test func privatePEMRoundTripsFreshKey() throws {
        // 不依赖 Keychain：生成 → PEM → 重建 → 公钥一致。
        let (mgr, _) = makeManager()
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ] as CFDictionary, &err)!
        let pem = mgr.privatePEM(priv)
        let rebuilt = try mgr.secKey(fromPrivatePEM: pem)
        #expect(mgr.publicPEM(SecKeyCopyPublicKey(rebuilt)!) ==
                mgr.publicPEM(SecKeyCopyPublicKey(priv)!))
    }

    @Test func keysAreP256() throws {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }

        _ = try mgr.ensureKeyPair()
        let priv = try mgr.loadPrivateKey()
        let pub = SecKeyCopyPublicKey(priv)!
        let attrs = SecKeyCopyAttributes(pub) as! [String: Any]
        #expect(attrs[kSecAttrKeyType as String] as? Int == kSecAttrKeyTypeECSECPrimeRandom as? Int)
        #expect(attrs[kSecAttrKeySizeInBits as String] as? Int == 256)
        #expect((SecKeyCopyExternalRepresentation(pub, nil)! as Data).count == 65)
        #expect((SecKeyCopyExternalRepresentation(priv, nil)! as Data).count == 97)
    }

    @Test func malformedStoredPEMThrows() {
        let (mgr, store) = makeManager()
        defer { try? store.deletePrivateKey() }
        try? store.savePrivateKey(Data("garbage".utf8))
        #expect(throws: VCPKeyManager.KeyError.malformedStoredKey) {
            _ = try mgr.loadPrivateKey()
        }
    }

    @Test func independentManagersDoNotShareKeys() throws {
        let (a, sa) = makeManager()
        let (b, sb) = makeManager()
        defer { try? sa.deletePrivateKey(); try? sb.deletePrivateKey() }
        #expect(try a.ensureKeyPair() != b.ensureKeyPair())
    }
}
