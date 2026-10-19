import Foundation
import Security
import Testing

@testable import TesBar

/// VCPKeyManager 现为共享内置密钥（ADR-0004）：不再生成/存储，只从
/// ``BuildConfig`` 私钥 PEM 重建 SecKey 并推导公钥。单测用临时 PEM 走
/// `secKey(fromPrivatePEM:)` / `publicPEM(fromPrivatePEM:)` 这些纯函数路径。
struct VCPKeyManagerTests {
    /// 每个用例生成一把临时 P-256 密钥当作“构建注入私钥”。
    private func makePEM() throws -> (pem: String, priv: SecKey) {
        var err: Unmanaged<CFError>?
        let priv = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ] as CFDictionary, &err)!
        let mgr = VCPKeyManager()
        let pem = try {
            // SEC1 包装：raw 外表示 point65||scalar32 → 手工 DER（同实现路径的反向）。
            let raw = SecKeyCopyExternalRepresentation(priv, nil)! as Data
            func tlv(_ tag: UInt8, _ content: Data) -> Data {
                [tag] + [UInt8(content.count)] + content
            }
            let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
            let sec1 = [tlv(0x02, Data([1])),
                        tlv(0x04, raw.suffix(32)),
                        tlv(0xA0, tlv(0x06, p256OID)),
                        tlv(0xA1, tlv(0x03, Data([0x00]) + raw.prefix(65)))]
                .reduce(into: Data(), +=)
            let der = tlv(0x30, sec1)
            let b64 = der.base64EncodedString()
            var out = "-----BEGIN EC PRIVATE KEY-----\n"
            var start = b64.startIndex
            while start < b64.endIndex {
                let end = b64.index(start, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
                out += b64[start..<end] + "\n"
                start = end
            }
            return out + "-----END EC PRIVATE KEY-----\n"
        }()
        return (pem, priv)
    }

    @Test func secKeyFromPrivatePEMRebuildsAndDerivesSamePublicKey() throws {
        let (pem, priv) = try makePEM()
        let mgr = VCPKeyManager()
        let rebuilt = try mgr.secKey(fromPrivatePEM: pem)
        #expect(mgr.publicPEM(SecKeyCopyPublicKey(rebuilt)!) ==
                mgr.publicPEM(SecKeyCopyPublicKey(priv)!))
    }

    @Test func publicPEMRebuildsViaSecKeyCreateWithData() throws {
        let (pem, _) = try makePEM()
        let mgr = VCPKeyManager()
        let pubPEM = try mgr.publicPEM(fromPrivatePEM: pem)
        let pub = try mgr.secKey(fromPublicPEM: pubPEM)
        #expect(mgr.publicPEM(pub) == pubPEM)
    }

    @Test func keysAreP256() throws {
        let (pem, _) = try makePEM()
        let mgr = VCPKeyManager()
        let priv = try mgr.secKey(fromPrivatePEM: pem)
        let pub = SecKeyCopyPublicKey(priv)!
        let attrs = SecKeyCopyAttributes(pub) as! [String: Any]
        #expect(attrs[kSecAttrKeyType as String] as? Int == kSecAttrKeyTypeECSECPrimeRandom as? Int)
        #expect(attrs[kSecAttrKeySizeInBits as String] as? Int == 256)
        #expect((SecKeyCopyExternalRepresentation(pub, nil)! as Data).count == 65)
        #expect((SecKeyCopyExternalRepresentation(priv, nil)! as Data).count == 97)
    }

    @Test func malformedPEMThrows() {
        let mgr = VCPKeyManager()
        #expect(throws: VCPKeyManager.KeyError.malformedStoredKey) {
            _ = try mgr.secKey(fromPrivatePEM: "garbage")
        }
    }

    /// ADR-0004 的行为锚点：同一私钥 PEM（共享分发）处处推导同一公钥。
    @Test func samePEMDerivesSamePublicKeyEverywhere() throws {
        let (pem, _) = try makePEM()
        let a = VCPKeyManager()
        let b = VCPKeyManager()
        #expect(try a.publicPEM(fromPrivatePEM: pem) == b.publicPEM(fromPrivatePEM: pem))
    }
}
