import Foundation
import Security

/// VCP 密钥对：prime256v1（P-256）。ECDH+HMAC 会话密钥来源（ticket 12），本类型不做签名。
/// 私钥以 SEC1（RFC 5915）PEM 存 Keychain；公钥以 SPKI PEM 供 `.well-known` 托管与配对展示。
public struct VCPKeyManager: Sendable {
    public enum KeyError: Error, Equatable {
        case generationFailed(String)
        case malformedStoredKey
    }

    private let store: KeychainStore

    public init(store: KeychainStore = KeychainStore()) {
        self.store = store
    }

    /// 幂等：Keychain 无私钥则生成 P-256 对并持久化；返回公钥 PEM（`-----BEGIN PUBLIC KEY-----`）。
    @discardableResult
    public func ensureKeyPair() throws -> String {
        if let stored = try? store.readPrivateKey(),
           let pubPEM = try? publicPEM(fromPrivatePEM: String(decoding: stored, as: UTF8.self)) {
            return pubPEM
        }
        var cfError: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey([
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ] as CFDictionary, &cfError) else {
            throw KeyError.generationFailed(String(describing: cfError?.takeRetainedValue()))
        }
        try store.savePrivateKey(Data(privatePEM(priv).utf8))
        return publicPEM(SecKeyCopyPublicKey(priv)!)
    }

    /// 从 Keychain PEM 重建私钥 SecKey（供 ticket 12 做 ECDH）。
    public func loadPrivateKey() throws -> SecKey {
        try secKey(fromPrivatePEM: String(decoding: try store.readPrivateKey(), as: UTF8.self))
    }

    // MARK: - PEM 编码

    /// 私钥 PEM（`-----BEGIN EC PRIVATE KEY-----`，SEC1）。
    /// SecKeyCopyExternalRepresentation 的私钥外表示是 raw ANSI X9.63（point65||scalar32），
    /// 此处自行包装为 DER。注意：本机 Security 框架（macOS 27）的 SecKeyCreateWithData
    /// 只接受 raw 形式、拒绝 DER 输入（SEC1/PKCS#8/SPKI 均报 -50），因此 PEM 仅作存储与
    /// 外部互操作格式，重建时解包回 raw。
    func privatePEM(_ priv: SecKey) -> String {
        let raw = SecKeyCopyExternalRepresentation(priv, nil)! as Data
        let sec1 = [tlv(0x02, Data([1])),                    // version = 1
                    tlv(0x04, raw.suffix(32)),               // privateKey scalar（raw = point||scalar）
                    tlv(0xA0, tlv(0x06, p256OID)),           // [0] namedCurve OBJECT
                    tlv(0xA1, tlv(0x03, Data([0x00]) + raw.prefix(65)))] // [1] publicKey point
            .reduce(into: Data(), +=)
        let sec1DER = tlv(0x30, sec1)
        return Self.wrapPEM(header: "EC PRIVATE KEY", der: sec1DER)
    }

    /// 公钥 PEM（`-----BEGIN PUBLIC KEY-----`，SPKI DER）。
    /// 本机公钥外表示是 raw 65B 点（非 SPKI），自行包装：
    /// SEQUENCE{ SEQUENCE{OID id-ecPublicKey, OID P-256}, BIT STRING(0x00||point) }。
    func publicPEM(_ key: SecKey) -> String {
        let point = SecKeyCopyExternalRepresentation(key, nil)! as Data
        let spki = tlv(0x30, algSEQ + tlv(0x03, Data([0x00]) + point))
        return Self.wrapPEM(header: "PUBLIC KEY", der: spki)
    }

    func publicPEM(fromPrivatePEM pem: String) throws -> String {
        publicPEM(SecKeyCopyPublicKey(try secKey(fromPrivatePEM: pem))!)
    }

    // MARK: - PEM 重建

    /// SEC1 PEM → 私钥 SecKey（内部转 raw scalar||point 供 SecKeyCreateWithData）。
    func secKey(fromPrivatePEM pem: String) throws -> SecKey {
        guard let sec1 = derBody(pem),
              let key = createKey(rawSEC1: sec1, class: kSecAttrKeyClassPrivate)
        else { throw KeyError.malformedStoredKey }
        return key
    }

    /// SPKI PEM → 公钥 SecKey。可用于校验托管公钥可被对端/本端重建。
    func secKey(fromPublicPEM pem: String) throws -> SecKey {
        guard let spki = derBody(pem),
              let key = createKey(rawSPKI: spki, class: kSecAttrKeyClassPublic)
        else { throw KeyError.malformedStoredKey }
        return key
    }

    // SecKeyCreateWithData 在本机只吃 raw：私钥 scalar32||point65，公钥 point65。
    private func createKey(rawSEC1 sec1: Data, class keyClass: CFString) -> SecKey? {
        var outer = TLVReader(sec1)
        guard let body = outer.read(expected: 0x30) else { return nil } // SEQUENCE 内容
        var seq = TLVReader(body)
        guard seq.read(expected: 0x02) != nil,          // version
              let scalar = seq.read(expected: 0x04),     // privateKey
              let ctx0 = seq.read(expected: 0xA0),       // [0] contents = OID TLV
              ctx0 == tlv(0x06, p256OID),                // namedCurve P-256
              let ctx1 = seq.read(expected: 0xA1),       // [1] BIT STRING point
              ctx1.count == 68, ctx1[ctx1.startIndex] == 0x03 // 66B BIT STRING
        else { return nil }
        let raw = ctx1.suffix(65) + scalar  // point || scalar，SecKeyCreateWithData 要求的 raw 形式
        return SecKeyCreateWithData(
            raw as CFData,
            [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass as String: keyClass] as CFDictionary,
            nil
        )
    }

    private func createKey(rawSPKI spki: Data, class keyClass: CFString) -> SecKey? {
        var outer = TLVReader(spki)
        guard let body = outer.read(expected: 0x30) else { return nil } // SEQUENCE 内容
        var seq = TLVReader(body)
        guard seq.read(expected: 0x30) == algSEQ.dropFirst(2),  // AlgorithmIdentifier 内容
              let bit = seq.read(expected: 0x03),        // BIT STRING point
              bit.count == 66, bit[bit.startIndex] == 0x00 // 0x00 前缀 + 65B 点
        else { return nil }
        return SecKeyCreateWithData(
            bit.suffix(65) as CFData,
            [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
             kSecAttrKeyClass as String: keyClass] as CFDictionary,
            nil
        )
    }
}

// MARK: - DER 最小工具（仅覆盖自产 P-256 SEC1/SPKI）

private let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]) // 1.2.840.10045.3.1.7
private let ecPublicKeyOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])     // 1.2.840.10045.2.1
private let algSEQ = tlv(0x30, tlv(0x06, ecPublicKeyOID) + tlv(0x06, p256OID)) // dropFirst(2) = 内容

/// DER 内容。// ponytail: 长度最长两字节，>65535 内容需多字节长度（本格式不会出现）
private func tlv(_ tag: UInt8, _ content: Data) -> Data {
    var out = Data([tag])
    let len = content.count
    if len < 128 {
        out.append(UInt8(len))
    } else if len < 256 {
        out.append(contentsOf: [0x81, UInt8(len)])
    } else {
        out.append(contentsOf: [0x82, UInt8(len >> 8), UInt8(len & 0xFF)])
    }
    return out + content
}

/// 顺序读取 DER TLV；错误即返回 nil，调用方整体判失败。
private struct TLVReader {
    let data: Data
    private var i: Data.Index

    init(_ data: Data) {
        self.data = data
        self.i = data.startIndex
    }

    mutating func read(expected tag: UInt8) -> Data? {
        let start = i
        guard start < data.endIndex, data[start] == tag else { return nil }
        var j = data.index(after: start)
        guard j < data.endIndex else { return nil }
        var len = 0
        switch data[j] {
        case let n where n < 0x80: len = Int(n); j = data.index(after: j)
        case 0x81:
            j = data.index(after: j)
            guard j < data.endIndex else { return nil }
            len = Int(data[j]); j = data.index(after: j)
        case 0x82:
            j = data.index(after: j)
            guard data.distance(from: j, to: data.endIndex) >= 2 else { return nil }
            len = Int(data[j]) << 8 | Int(data[data.index(after: j)])
            j = data.index(j, offsetBy: 2)
        default: return nil
        }
        guard data.distance(from: j, to: data.endIndex) >= len else { return nil }
        i = data.index(j, offsetBy: len)
        return data[j..<i]
    }
}

private func derBody(_ pem: String) -> Data? {
    let b64 = pem.split(whereSeparator: \.isNewline)
        .filter { !$0.hasPrefix("-----") }
        .joined()
    return Data(base64Encoded: String(b64))
}

extension VCPKeyManager {
    fileprivate static func wrapPEM(header: String, der: Data) -> String {
        let b64 = der.base64EncodedString()
        var out = "-----BEGIN \(header)-----\n"
        var start = b64.startIndex
        while start < b64.endIndex {
            let end = b64.index(start, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            out += b64[start..<end]
            out += "\n"
            start = end
        }
        out += "-----END \(header)-----\n"
        return out
    }
}
