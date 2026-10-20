import Foundation
import CryptoKit
import Security
import Testing
@testable import TesBar

// Official test vectors from github.com/teslamotors/vehicle-command pkg/protocol/protocol.md.

private func hex(_ s: String) -> Data {
    var out = Data()
    var iter = s.makeIterator()
    while let h = iter.next(), let l = iter.next() {
        out.append(UInt8(String([h, l]), radix: 16)!)
    }
    return out
}

/// Raw scalar → SecKey for official vectors. Apple's native private-key format is
/// ENCODE_PUBLIC(C) || scalar (97B) — what SecKeyCopyExternalRepresentation emits and
/// SecKeyCreateWithData expects; documented nowhere, verified by round-trip.
private func importPrivateKey(_ scalar: Data, publicPoint: Data) throws -> SecKey {
    let raw = publicPoint + scalar
    let attrs: [CFString: Any] = [
        kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        kSecAttrKeySizeInBits: 256,
    ]
    guard let key = SecKeyCreateWithData(raw as CFData, attrs as CFDictionary, nil) else {
        throw VCPError.keyExchangeFailed
    }
    return key
}

/// protocol.md "Key Agreement": K = 1b2fce19967b79db696f909cff89ea9a from the
/// official client.key/vehicle.pem pair. Exercises real SecKey ECDH, not hex constants.
@Test func officialVectorECDH() throws {
    let clientPriv = hex("2538CDC29A97C19C1E99A637D6CF4F8C970C118B56EDE1E6323E6D162C4B30DB")
    let clientPub = hex("04b2b6bc68c2da0665ce656815594996c62394edd8bea905fe781a754fe6a845a714330902f225e9269d466e05b349981fda9d85cc23c6fb444aa73b629105dc6e")
    let vehiclePub = hex("04c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d97")
    let key = try importPrivateKey(clientPriv, publicPoint: clientPub)
    let sx = try ECKeyPair.sharedSecret(privateKey: key, peerPublicKey: vehiclePub)
    #expect(SessionCrypto.sharedKey(fromSecret: sx) == hex("1b2fce19967b79db696f909cff89ea9a"))
}

/// protocol.md "Response authentication": SESSION_INFO_KEY and the full
/// metadata || session_info → tag vector.
@Test func officialVectorSessionInfoVerification() throws {
    let k = hex("1b2fce19967b79db696f909cff89ea9a")
    #expect(SessionCrypto.sessionInfoKey(k) == hex("fceb679ee7bca756fcd441bf238bf2f338629b41d9eb9c67be1b32c9672ce300"))

    let sessionInfoBytes = hex(
        "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d971a104c463f9cc0d3d26906e982ed224adde6255a0a0000")
    let challenge = hex("1588d5a30eabc6f8fc9a951b11f6fd11")
    let tag = hex("996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002")
    #expect(SessionCrypto.verifySessionInfo(
        tag: tag, sessionInfoBytes: sessionInfoBytes, vin: "5YJ30123456789ABC",
        challenge: challenge, k: k))
    var tampered = tag
    tampered[tampered.startIndex] ^= 1
    #expect(!SessionCrypto.verifySessionInfo(
        tag: tampered, sessionInfoBytes: sessionInfoBytes, vin: "5YJ30123456789ABC",
        challenge: challenge, k: k))
    // Wrong session info (truncated) must also fail.
    #expect(!SessionCrypto.verifySessionInfo(
        tag: tag, sessionInfoBytes: sessionInfoBytes.prefix(sessionInfoBytes.count - 1),
        vin: "5YJ30123456789ABC", challenge: challenge, k: k))
}

/// protocol.md "Metadata serialization" examples, byte for byte.
@Test func metadataTLVMatchesOfficialExamples() {
    // SERIALIZE({COUNTER: 100, VIN: "abc"}) = 0x0203616263 05 04 00000064 FF
    let meta = AuthMetadata(
        signatureType: 0, personalization: Array("abc".utf8), counter: 100)
    #expect(meta.serialized == hex("0203616263050400000064ff"))
    // (Official example omits zero-valued signatureType; exactly the doc's SERIALIZE output.)

    // Session-info vector metadata (uses SIGNATURE_TYPE_HMAC = 6, no domain).
    let hand = AuthMetadata(
        signatureType: 6, personalization: Array("5YJ30123456789ABC".utf8),
        challenge: Array(hex("1588d5a30eabc6f8fc9a951b11f6fd11")))
    #expect(hand.serialized == hex(
        "000106021135594a333031323334353637383941424306101588d5a30eabc6f8fc9a951b11f6fd11ff"))
}

/// protocol.md "HMAC-SHA256 authentication" section: the documented command metadata
/// (counter 7, flags 2, expires 2655) — byte-exact, with the AES-GCM sig type from the doc.
@Test func commandMetadataMatchesOfficialLayout() {
    let m = AuthMetadata(
        signatureType: 5, domain: .infotainment, personalization: Array("5YJ30123456789ABC".utf8),
        epoch: Array(hex("4c463f9cc0d3d26906e982ed224adde6")), expiresAt: 2655, counter: 7, flags: 2)
    #expect(m.serialized == hex(
        "000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6040400000a5f050400000007070400000002ff"))
    var zeroFlags = m
    zeroFlags.flags = 0
    #expect(!zeroFlags.serialized.contains(Data([0x07, 0x04]))) // no TAG_FLAGS item
}

/// protocol.md "Message encoding": decode the exact TX bytes from the debug log.
@Test func officialRoutableMessageBytesDecode() throws {
    let tx = try RoutableMessage.decode(hex(
        "320208023a1212100a7962c10d38b61dd2a7722780a4f0969a031005514f57616bcc81a8ce0f9d7b48322952040a020805"))
    #expect(tx.toDomain == .vcsec)
    #expect(tx.fromRoutingAddress == hex("0a7962c10d38b61dd2a7722780a4f096"))
    #expect(tx.payload == hex("0a020805"))
    #expect(tx.uuid == hex("05514f57616bcc81a8ce0f9d7b483229"))
    #expect(tx.flags == 0)
}

/// protocol.md command encoding example: hvacAuto power_on=true → 120452020801.
@Test func officialHvacAutoPayloadVector() {
    #expect(CarServerAction.hvacAuto(powerOn: true).encoded() == hex("120452020801"))
}

/// Writer → reader round trip across varint edge cases, plus unknown-field skipping.
@Test func protobufWriterReaderRoundTrip() throws {
    var w = ProtobufWriter()
    w.writeField(1, UInt32(300)) // multi-byte varint
    w.writeField(2, UInt32(1))
    w.writeField(99, bytes: Data([0xC0, 0xFF])) // field the reader ignores
    w.writeFixed32(3, 0x0A5F)
    var r = ProtobufReader(w.data)
    var values: [Int: UInt64] = [:]
    var fixed32: UInt32?
    while let (f, wt) = try r.nextField() {
        switch wt {
        case 0: values[f] = try r.readVarint()
        case 2: _ = try r.readBytes()
        case 5:
            var raw: UInt32 = 0
            for i in 0..<4 { raw |= UInt32(w.data[w.data.startIndex + r.index + i]) << (8 * i) }
            _ = try r.readFloat()
            fixed32 = raw
        default: try r.skip(wireType: wt)
        }
    }
    #expect(values[1] == 300 && values[2] == 1 && values[99] == nil)
    #expect(fixed32 == 0x0A5F)
}

/// SessionInfo decode against official vector bytes.
@Test func sessionInfoDecodesOfficialVector() throws {
    let info = try SessionInfo.decode(hex(
        "0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d971a104c463f9cc0d3d26906e982ed224adde6255a0a0000"))
    #expect(info.counter == 6)
    #expect(info.clockTime == 2650)
    #expect(info.epoch == hex("4c463f9cc0d3d26906e982ed224adde6"))
    #expect(info.publicKey.count == 65)
}

/// MessageFault decoding from wire bytes (RoutableMessage.signedMessageStatus).
@Test func messageFaultDecodesFromSampleBytes() throws {
    let faults: [(MessageFault, UInt32)] = [
        (.unknownKeyID, 3), (.invalidSignature, 5), (.invalidTokenOrCounter, 6),
        (.incorrectEpoch, 15), (.timeExpired, 17), (.remoteAccessDisabled, 21),
    ]
    for (expected, raw) in faults {
        var w = ProtobufWriter()
        w.writeField(12) { w in
            w.writeField(1, 2) // OPERATIONSTATUS_ERROR
            w.writeField(2, raw)
        }
        let decoded = try RoutableMessage.decode(w.data)
        #expect(decoded.messageFault == expected, "fault \(raw)")
    }
    // Unknown raw value is kept verbatim — never silently dropped to "success".
    var w = ProtobufWriter()
    w.writeField(12) { $0.writeField(2, 99) }
    #expect(try RoutableMessage.decode(w.data).messageFault == .unknown(99))
}

/// VCSEC command encodings spot-checked against field numbers in vcsec.proto.
@Test func vcsecEncodings() {
    #expect(encodeVCSECUnsignedMessage(rkeAction: .lock) == hex("1001")) // RKEAction(2)=1
    // proto2 presence: set field serializes even at 0 — unlock = `10 00`
    // (empty UnsignedMessage is what Fleet API 400s on; ticket 16).
    #expect(encodeVCSECUnsignedMessage(rkeAction: .unlock) == hex("1000"))
    #expect(encodeVCSECUnsignedMessage(rkeAction: .remoteDrive) == hex("1014"))
    #expect(encodeVCSECUnsignedMessage(rkeAction: .wakeVehicle) == hex("101e"))
    // ClosureMoveRequest(frontTrunk=6: OPEN=3) → 22 02 30 03
    #expect(encodeVCSECUnsignedMessage(
        closureMove: VCSECClosureMoveRequest(frontTrunk: .open)) == hex("22023003"))
    // rearTrunk=5 CLOSE=4 → 22 02 28 04
    #expect(encodeVCSECUnsignedMessage(
        closureMove: VCSECClosureMoveRequest(rearTrunk: .close)) == hex("22022804"))
}

/// ECDH symmetry via real SecKeys.
@Test func ecdhSymmetry() throws {
    let a = try ECKeyPair.generate()
    let b = try ECKeyPair.generate()
    let s1 = try ECKeyPair.sharedSecret(privateKey: a.privateKey, peerPublicKey: b.publicKeyData)
    let s2 = try ECKeyPair.sharedSecret(privateKey: b.privateKey, peerPublicKey: a.publicKeyData)
    #expect(s1 == s2)
    #expect(a.publicKeyData.count == 65)
}

func makeSession(vehicleKey: () throws -> (privateKey: SecKey, publicKeyData: Data)) throws
    -> (session: VCPSession, client: (privateKey: SecKey, publicKeyData: Data))
{
    let client = try ECKeyPair.generate()
    let vehicle = try vehicleKey()
    let k = SessionCrypto.sharedKey(
        fromSecret: try ECKeyPair.sharedSecret(
            privateKey: client.privateKey, peerPublicKey: vehicle.publicKeyData))
    let session = VCPSession(
        epoch: Data(repeating: 0x4C, count: 16), counter: 6, clockTime: 2650,
        vehiclePublicKey: vehicle.publicKeyData, k: k)
    return (session, client)
}

/// Determinism: identical inputs (incl. uuid/routing) → identical bytes; differing uuid
/// changes only that field. Acceptance criterion "同输入除 uuid/routing_address 外字段一致".
@Test func authenticatedCommandDeterminism() throws {
    let (session, client) = try makeSession { try ECKeyPair.generate() }
    let payload = CarServerAction.hvacAuto(powerOn: true).encoded()
    func build(uuid: Data) -> Data {
        SessionCrypto.authenticatedCommand(
            payload: payload, domain: .infotainment, vin: "5YJ30123456789ABC", session: session,
            clientPublicKey: client.publicKeyData, uuid: uuid,
            routingAddress: Data(repeating: 4, count: 16), expiresAt: 2655, counter: 7)
    }
    let uuid = Data(repeating: 3, count: 16)
    #expect(build(uuid: uuid) == build(uuid: uuid)) // byte-identical
    let a = try RoutableMessage.decode(build(uuid: uuid))
    let b = try RoutableMessage.decode(build(uuid: Data(repeating: 5, count: 16)))
    #expect(a.toDomain == b.toDomain)
    #expect(a.payload == b.payload)
    #expect(a.signatureData == b.signatureData) // tag deterministic given metadata+payload
    #expect(a.flags == 2 && a.uuid == uuid)
}

/// Acceptance: independent recomputation — decode the emitted message, rebuild K' from
/// K on the test side, recompute HMAC over reconstructed metadata+payload, compare.
@Test func authenticatedCommandTagVerifiesIndependently() throws {
    let (session, client) = try makeSession { try ECKeyPair.generate() }
    let payload = encodeVCSECUnsignedMessage(rkeAction: .lock)
    let bytes = SessionCrypto.authenticatedCommand(
        payload: payload, domain: .vcsec, vin: "5YJ30123456789ABC", session: session,
        clientPublicKey: client.publicKeyData, uuid: Data(repeating: 9, count: 16),
        routingAddress: Data(repeating: 2, count: 16), expiresAt: 2655, counter: 7)

    let msg = try RoutableMessage.decode(bytes)
    #expect(msg.payload == payload)
    #expect(msg.toDomain == .vcsec)
    #expect(msg.flags == 2)

    // Test-side rebuild, sharing only K.
    let kPrime = SessionCrypto.authenticatedCommandKey(session.k)
    let metadata = AuthMetadata(
        signatureType: 8, domain: .vcsec, personalization: Array("5YJ30123456789ABC".utf8),
        epoch: Array(session.epoch), expiresAt: 2655, counter: 7, flags: 2).serialized
    var signed = metadata
    signed.append(payload)
    let expected = Data(HMAC<SHA256>.authenticationCode(
        for: signed, using: SymmetricKey(data: kPrime)))

    // Extract HMAC_Personalized_data.tag from the embedded SignatureData.
    var sig = ProtobufReader(msg.signatureData!)
    var embeddedTag: Data?
    var signerKey: Data?
    try sig.forEachField { r, field, wireType in
        switch field {
        case 1:
            var id = ProtobufReader(try r.readBytes())
            try id.forEachField { id, f, wt in
                if f == 1 { signerKey = try id.readBytes() } else { try id.skip(wireType: wt) }
            }
        case 8:
            var d = ProtobufReader(try r.readBytes())
            try d.forEachField { d, f, wt in
                if f == 4 { embeddedTag = try d.readBytes() } else { try d.skip(wireType: wt) }
            }
        default: try r.skip(wireType: wireType)
        }
    }
    #expect(signerKey == client.publicKeyData)
    #expect(embeddedTag == expected)
}
