import Foundation
import CryptoKit
import Security

// MARK: - Session crypto (ECDH P-256 → K, KDF labels, HMAC auth)

/// One established session with a vehicle domain (result of a verified handshake).
/// Consumed by ticket 05 to authorize commands.
struct VCPSession: Sendable {
    var epoch: Data
    /// Last authenticated counter; commands use counter + 1.
    var counter: UInt32
    /// Vehicle clock seconds for this epoch.
    var clockTime: UInt32
    /// Vehicle public key (65B uncompressed) from session_info.
    var vehiclePublicKey: Data
    /// K = SHA1(BIG_ENDIAN(Sx,32))[:16].
    var k: Data
}

/// P-256 keypair helpers over SecKey.
enum ECKeyPair {
    /// Generates a fresh prime256v1 keypair.
    static func generate() throws -> (privateKey: SecKey, publicKeyData: Data) {
        let parameters: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let priv = SecKeyCreateRandomKey(parameters as CFDictionary, nil) else {
            throw VCPError.keyGenerationFailed
        }
        return (priv, try encodePublicKey(SecKeyCopyPublicKey(priv)!))
    }

    /// 0x04 || BE(x,32) || BE(y,32) (ENCODE_PUBLIC in protocol.md).
    static func encodePublicKey(_ key: SecKey) throws -> Data {
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
            data.count == 65, data.first == 0x04
        else { throw VCPError.invalidPublicKey }
        return data
    }

    /// ECDH shared secret: returns BIG_ENDIAN(Sx, 32).
    static func sharedSecret(privateKey: SecKey, peerPublicKey: Data) throws -> Data {
        let params: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
        ]
        guard let peer = SecKeyCreateWithData(peerPublicKey as CFData, params as CFDictionary, nil),
            let s = SecKeyCopyKeyExchangeResult(
                privateKey, .ecdhKeyExchangeStandard, peer, [:] as CFDictionary, nil) as Data?,
            s.count == 32
        else { throw VCPError.keyExchangeFailed }
        return s
    }
}

enum VCPError: Error, Equatable {
    case keyGenerationFailed
    case invalidPublicKey
    case keyExchangeFailed
}

/// Metadata TLV (Signatures.Tag): tags ascending, each `tag(1) || len(1) || value`,
/// ints big-endian 4 bytes, terminated by 0xFF. Byte-exact against protocol.md vectors.
struct AuthMetadata: Sendable {
    /// SIGNATURE_TYPE_HMAC_PERSONALIZED = 8 (commands); SIGNATURE_TYPE_HMAC = 6 (session info).
    var signatureType: UInt8
    var domain: VCPDomain?
    var personalization: [UInt8]?
    var epoch: [UInt8]?
    var expiresAt: UInt32?
    var counter: UInt32?
    /// Only emitted when non-zero (outgoing requests).
    var flags: UInt32?
    /// Session-info verification only.
    var challenge: [UInt8]?
    var serialized: Data {
        var items: [(UInt8, [UInt8])] = signatureType != 0 ? [(0, [signatureType])] : [] // TAG_SIGNATURE_TYPE
        if let domain { items.append((1, [UInt8(domain.rawValue)])) } // TAG_DOMAIN
        if let personalization { items.append((2, personalization)) } // TAG_PERSONALIZATION
        if let epoch { items.append((3, epoch)) } // TAG_EPOCH
        if let expiresAt { items.append((4, be32(expiresAt))) } // TAG_EXPIRES_AT
        if let counter { items.append((5, be32(counter))) } // TAG_COUNTER
        if let challenge { items.append((6, challenge)) } // TAG_CHALLENGE
        if let flags, flags != 0 { items.append((7, be32(flags))) } // TAG_FLAGS
        var out = Data(capacity: 8 + (personalization?.count ?? 0) + (epoch?.count ?? 0))
        for (tag, value) in items.sorted(by: { $0.0 < $1.0 }) {
            out.append(contentsOf: [tag, UInt8(value.count)])
            out.append(contentsOf: value)
        }
        out.append(0xFF) // TAG_END
        return out
    }

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }
}

/// Pure-function session crypto: K, K', session-info verification, authenticated commands.
enum SessionCrypto {
    /// K = SHA1(BIG_ENDIAN(Sx, 32))[:16].
    static func sharedKey(fromSecret sx: Data) -> Data {
        Data(Insecure.SHA1.hash(data: sx)).prefix(16)
    }

    /// SESSION_INFO_KEY = HMAC-SHA256(K, "session info").
    static func sessionInfoKey(_ k: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data("session info".utf8), using: SymmetricKey(data: k)))
    }

    /// K' = HMAC-SHA256(K, "authenticated command").
    static func authenticatedCommandKey(_ k: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data("authenticated command".utf8), using: SymmetricKey(data: k)))
    }

    /// Verifies a handshake response: tag = HMAC(SESSION_INFO_KEY, TLV(sigType=HMAC, VIN,
    /// challenge) || 0xFF-already-in-TLV || session_info bytes).
    static func verifySessionInfo(
        tag: Data, sessionInfoBytes: Data, vin: String, challenge: Data, k: Data
    ) -> Bool {
        let metadata = AuthMetadata(
            signatureType: 6, personalization: Array(vin.utf8), challenge: Array(challenge)
        ).serialized
        var signed = metadata
        signed.append(sessionInfoBytes)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: signed, using: SymmetricKey(data: sessionInfoKey(k))))
        return timingSafeEqual(tag, expected)
    }

    /// tag = HMAC-SHA256(K', M || P) where M is the serialized metadata (ends with 0xFF).
    static func commandTag(key kPrime: Data, metadata: Data, payload: Data) -> Data {
        var signed = metadata
        signed.append(payload)
        return Data(HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: kPrime)))
    }

    /// Assembles the full authenticated command RoutableMessage (plaintext payload,
    /// HMAC_PERSONALIZED signature). `counter` must be `session.counter + 1`;
    /// `expiresAt` is in vehicle-domain seconds.
    static func authenticatedCommand(
        payload: Data, domain: VCPDomain, vin: String, session: VCPSession,
        clientPublicKey: Data, uuid: Data, routingAddress: Data,
        expiresAt: UInt32, counter: UInt32, flags: UInt32 = 2
    ) -> Data {
        let metadata = AuthMetadata(
            signatureType: 8, domain: domain, personalization: Array(vin.utf8),
            epoch: Array(session.epoch), expiresAt: expiresAt, counter: counter, flags: flags
        ).serialized
        let tag = commandTag(
            key: authenticatedCommandKey(session.k), metadata: metadata, payload: payload)
        let signatureData = SignatureData(
            epoch: session.epoch, counter: counter, expiresAt: expiresAt, tag: tag
        ).encoded(signerPublicKey: clientPublicKey)
        return RoutableMessage(
            toDomain: domain,
            fromRoutingAddress: routingAddress,
            payload: payload,
            signatureData: signatureData,
            uuid: uuid,
            flags: flags
        ).encoded()
    }
}
