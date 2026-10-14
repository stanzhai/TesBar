import Foundation

// MARK: - Protobuf wire format (proto3 subset used by VCP)

/// Encodes proto3 wire format: varint, tag-delimited, uint32/enum/bool/bytes/float/double.
/// Field order follows the official .proto files; default values are omitted (proto3).
struct ProtobufWriter {
    private(set) var data = Data()

    /// Wire type 0 (varint) for uint32/enum/bool, keyed by field number.
    mutating func writeField(_ field: Int, _ value: UInt32) {
        writeTag(field, wireType: 0)
        writeVarint(UInt64(value))
    }

    mutating func writeField(_ field: Int, bool: Bool) {
        if bool { writeField(field, UInt32(1)) }
    }

    /// Wire type 5 (fixed32) — protobuf `fixed32` (e.g. SignatureData.expires_at).
    mutating func writeFixed32(_ field: Int, _ value: UInt32) {
        writeTag(field, wireType: 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Wire type 5 (fixed32) — protobuf `float`.
    mutating func writeField(_ field: Int, float: Float) {
        writeTag(field, wireType: 5)
        withUnsafeBytes(of: float.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Wire type 1 (fixed64) — protobuf `double`.
    mutating func writeField(_ field: Int, double: Double) {
        writeTag(field, wireType: 1)
        withUnsafeBytes(of: double.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Wire type 2 (length-delimited) for bytes/string/empty Void submessages.
    mutating func writeField(_ field: Int, bytes: Data) {
        writeTag(field, wireType: 2)
        writeVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    mutating func writeField(_ field: Int, message: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
        message(&nested)
        writeField(field, bytes: nested.data)
    }

    private mutating func writeTag(_ field: Int, wireType: Int) {
        writeVarint(UInt64(field << 3 | wireType))
    }

    mutating func writeVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }
}

enum ProtobufError: Error, Equatable {
    case truncated
    case malformedVarint
    /// Wire type the VCP subset never uses (groups).
    case unsupportedWireType(Int)
}

/// Decodes the proto3 subset the vehicle sends back: fields in any order, unknown fields skipped.
struct ProtobufReader {
    let data: Data
    private(set) var index: Int
    /// End of the current (sub)message.
    private let end: Int

    init(_ data: Data, range: Range<Int>? = nil) {
        self.data = data
        self.index = range?.lowerBound ?? 0
        self.end = range?.upperBound ?? data.count
    }

    var hasMore: Bool { index < end }

    /// Next (fieldNumber, wireType) or nil at end of message.
    mutating func nextField() throws -> (field: Int, wireType: Int)? {
        guard hasMore else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        guard field > 0 else { throw ProtobufError.malformedVarint }
        return (field, Int(key & 7))
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        while shift <= 63 {
            guard index < end else { throw ProtobufError.truncated }
            let byte = data[data.startIndex + index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtobufError.malformedVarint
    }

    mutating func readUInt32() throws -> UInt32 { UInt32(try readVarint()) }

    mutating func readBool() throws -> Bool { try readVarint() != 0 }

    /// Length-delimited bytes (also strings/submessages).
    mutating func readBytes() throws -> Data {
        let length = Int(try readVarint())
        guard index + length <= end else { throw ProtobufError.truncated }
        defer { index += length }
        return data.subdata(in: (data.startIndex + index)..<(data.startIndex + index + length))
    }

    mutating func readFloat() throws -> Float {
        try readFixed(width: 4) { Float(bitPattern: $0) }
    }

    /// Wire type 5 read as a raw uint32 (protobuf `fixed32`/`sfixed32`).
    mutating func readFixed32() throws -> UInt32 {
        try readFixed(width: 4) { $0 }
    }

    private mutating func readFixed<T>(width: Int, _ make: (UInt32) -> T) throws -> T {
        guard index + width <= end else { throw ProtobufError.truncated }
        var raw: UInt32 = 0
        for i in 0..<width { raw |= UInt32(data[data.startIndex + index + i]) << (8 * i) } // little-endian on wire
        index += width
        return make(raw)
    }

    /// Skips a field whose number the caller doesn't care about.
    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0: _ = try readVarint()
        case 1: try consume(8)
        case 5: try consume(4)
        case 2: _ = try readBytes()
        default: throw ProtobufError.unsupportedWireType(wireType)
        }
    }

    private mutating func consume(_ n: Int) throws {
        guard index + n <= end else { throw ProtobufError.truncated }
        index += n
    }

    /// Visits each field of the current message.
    mutating func forEachField(_ body: (inout ProtobufReader, Int, Int) throws -> Void) throws {
        while let (field, wireType) = try nextField() {
            try body(&self, field, wireType)
        }
    }
}

// MARK: - UniversalMessage

/// UniversalMessage.Domain subset.
enum VCPDomain: UInt32, Sendable {
    case vcsec = 2
    case infotainment = 3
}

/// UniversalMessage.MessageFault_E — known raw values plus unknown verbatim
/// (unknown is always a failure, never success).
enum MessageFault: Equatable, Sendable {
    case errorNone
    case busy
    case timeout
    case unknownKeyID
    case inactiveKey
    case invalidSignature
    case invalidTokenOrCounter
    case insufficientPrivileges
    case incorrectEpoch
    case timeExpired
    case remoteAccessDisabled
    /// Fault value outside the known set, kept verbatim.
    case unknown(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .errorNone
        case 1: self = .busy
        case 2: self = .timeout
        case 3: self = .unknownKeyID
        case 4: self = .inactiveKey
        case 5: self = .invalidSignature
        case 6: self = .invalidTokenOrCounter
        case 7: self = .insufficientPrivileges
        case 15: self = .incorrectEpoch
        case 17: self = .timeExpired
        case 21: self = .remoteAccessDisabled
        default: self = .unknown(rawValue)
        }
    }

    /// Wire value: known faults map back; unknown keeps its raw value.
    var wireValue: UInt32 {
        switch self {
        case .errorNone: 0
        case .busy: 1
        case .timeout: 2
        case .unknownKeyID: 3
        case .inactiveKey: 4
        case .invalidSignature: 5
        case .invalidTokenOrCounter: 6
        case .insufficientPrivileges: 7
        case .incorrectEpoch: 15
        case .timeExpired: 17
        case .remoteAccessDisabled: 21
        case .unknown(let raw): raw
        }
    }
}

/// Signatures.SessionInfo (handshake reply payload).
struct SessionInfo: Equatable, Sendable {
    var counter: UInt32
    var publicKey: Data
    var epoch: Data
    var clockTime: UInt32
    /// status(5) u32: 0 = OK, 1 = KEY_NOT_ON_WHITELIST (virtual key not paired).
    var status: UInt32

    /// counter(1) u32, publicKey(2) bytes, epoch(3) bytes, clock_time(4) fixed32, status(5) u32.
    static func decode(_ data: Data) throws -> SessionInfo {
        var r = ProtobufReader(data)
        var info = SessionInfo(counter: 0, publicKey: Data(), epoch: Data(), clockTime: 0, status: 0)
        try r.forEachField { r, field, wireType in
            switch (field, wireType) {
            case (1, 0): info.counter = try r.readUInt32()
            case (2, 2): info.publicKey = try r.readBytes()
            case (3, 2): info.epoch = try r.readBytes()
            case (4, 5): info.clockTime = try r.readFixed32()
            case (5, 0): info.status = try r.readUInt32()
            default: try r.skip(wireType: wireType)
            }
        }
        return info
    }
}

/// UniversalMessage.RoutableMessage — the fields the Fleet API path reads/writes.
/// Field numbers: to=6, from=7, status=12, payload=10, sigData=13, sessionInfoRequest=14,
/// sessionInfo=15, request_uuid=50, uuid=51, flags=52.
struct RoutableMessage: Equatable, Sendable {
    var toDomain: VCPDomain?
    var toRoutingAddress: Data?
    var fromRoutingAddress: Data?
    var payload: Data?
    var signatureData: Data?
    var sessionInfoRequestPublicKey: Data?
    var sessionInfo: Data?
    var messageFault: MessageFault?
    var requestUUID: Data?
    var uuid: Data?
    /// Always 2 (1 << FLAG_ENCRYPT_RESPONSE) on requests.
    var flags: UInt32

    init(
        toDomain: VCPDomain? = nil, toRoutingAddress: Data? = nil, fromRoutingAddress: Data? = nil,
        payload: Data? = nil, signatureData: Data? = nil,
        sessionInfoRequestPublicKey: Data? = nil, sessionInfo: Data? = nil,
        messageFault: MessageFault? = nil, requestUUID: Data? = nil, uuid: Data? = nil,
        flags: UInt32 = 0
    ) {
        self.toDomain = toDomain
        self.toRoutingAddress = toRoutingAddress
        self.fromRoutingAddress = fromRoutingAddress
        self.payload = payload
        self.signatureData = signatureData
        self.sessionInfoRequestPublicKey = sessionInfoRequestPublicKey
        self.sessionInfo = sessionInfo
        self.messageFault = messageFault
        self.requestUUID = requestUUID
        self.uuid = uuid
        self.flags = flags
    }

    func encoded() -> Data {
        var w = ProtobufWriter()
        w.writeField(6) { w in
            if let toDomain { w.writeField(1, toDomain.rawValue) }
            if let toRoutingAddress { w.writeField(2, bytes: toRoutingAddress) }
        }
        if let fromRoutingAddress {
            w.writeField(7) { $0.writeField(2, bytes: fromRoutingAddress) }
        }
        if let payload { w.writeField(10, bytes: payload) }
        if let signatureData { w.writeField(13, bytes: signatureData) }
        if let sessionInfoRequestPublicKey {
            w.writeField(14) { $0.writeField(1, bytes: sessionInfoRequestPublicKey) }
        }
        if let sessionInfo { w.writeField(15, bytes: sessionInfo) }
        if let messageFault {
            w.writeField(12) { w in
                w.writeField(1, 2) // operation_status = OPERATIONSTATUS_ERROR
                w.writeField(2, messageFault.wireValue)
            }
        }
        if let requestUUID { w.writeField(50, bytes: requestUUID) }
        if let uuid { w.writeField(51, bytes: uuid) }
        if flags != 0 { w.writeField(52, flags) }
        return w.data
    }

    static func decode(_ data: Data) throws -> RoutableMessage {
        var r = ProtobufReader(data)
        var msg = RoutableMessage()
        try r.forEachField { r, field, wireType in
            switch (field, wireType) {
            case (6, 2): msg.toDomain = try decodeDestination(try r.readBytes(), routing: &msg.toRoutingAddress)
            case (7, 2):
                var d = ProtobufReader(try r.readBytes())
                try d.forEachField { d, f, wt in
                    if f == 2, wt == 2 { msg.fromRoutingAddress = try d.readBytes() }
                    else { try d.skip(wireType: wt) }
                }
            case (10, 2): msg.payload = try r.readBytes()
            case (13, 2): msg.signatureData = try r.readBytes()
            case (14, 2):
                var d = ProtobufReader(try r.readBytes())
                try d.forEachField { d, f, wt in
                    if f == 1, wt == 2 { msg.sessionInfoRequestPublicKey = try d.readBytes() }
                    else { try d.skip(wireType: wt) }
                }
            case (15, 2): msg.sessionInfo = try r.readBytes()
            case (12, 2):
                var d = ProtobufReader(try r.readBytes())
                try d.forEachField { d, f, wt in
                    if f == 2, wt == 0 {
                        // init keeps unknown raw values verbatim, so callers report
                        // them as failures instead of reading the reply as success.
                        msg.messageFault = MessageFault(rawValue: try d.readUInt32())
                    } else { try d.skip(wireType: wt) }
                }
            case (50, 2): msg.requestUUID = try r.readBytes()
            case (51, 2): msg.uuid = try r.readBytes()
            case (52, 0): msg.flags = try r.readUInt32()
            default: try r.skip(wireType: wireType)
            }
        }
        return msg
    }

    /// Decodes Destination{domain(1), routing_address(2)}.
    private static func decodeDestination(_ body: Data, routing: inout Data?) throws -> VCPDomain? {
        var d = ProtobufReader(body)
        var domain: VCPDomain?
        try d.forEachField { d, f, wt in
            switch (f, wt) {
            case (1, 0): domain = VCPDomain(rawValue: (try? d.readUInt32()) ?? 0)
            case (2, 2): routing = try? d.readBytes()
            default: try? d.skip(wireType: wt)
            }
        }
        return domain
    }
}

// MARK: - Signatures.SignatureData (HMAC_PERSONALIZED)

/// Signatures.SignatureData carrying HMAC_Personalized_data (oneof arm 8).
/// HMAC_Personalized_Signature_Data: epoch(1), counter(2) u32, expires_at(3) fixed32, tag(4) bytes.
/// KeyIdentity: public_key(1) bytes — NOT 2, which is reserved (verified against signatures.proto).
struct SignatureData: Equatable, Sendable {
    var epoch: Data
    var counter: UInt32
    var expiresAt: UInt32
    var tag: Data

    func encoded(signerPublicKey: Data) -> Data {
        var w = ProtobufWriter()
        w.writeField(1) { $0.writeField(1, bytes: signerPublicKey) }
        w.writeField(8) { w in
            w.writeField(1, bytes: epoch)
            w.writeField(2, counter)
            w.writeFixed32(3, expiresAt) // fixed32 per signatures.proto
            w.writeField(4, bytes: tag)
        }
        return w.data
    }
}

// MARK: - VCSEC.UnsignedMessage

/// VCSEC.RKEAction_E subset.
enum RKEAction: UInt32, Sendable {
    case unlock = 0
    case lock = 1
    case remoteDrive = 20
    case wakeVehicle = 30
}

/// VCSEC.ClosureMoveType_E subset.
enum ClosureMoveType: UInt32, Sendable {
    case move = 1
    case stop = 2
    case open = 3
    case close = 4
}

/// VCSEC.ClosureMoveRequest — TesBar only actuates trunk(5)/frunk(6).
struct VCSECClosureMoveRequest: Equatable, Sendable {
    var frontTrunk: ClosureMoveType?
    var rearTrunk: ClosureMoveType?

    func encoded() -> Data {
        var w = ProtobufWriter()
        if let rearTrunk { w.writeField(5, rearTrunk.rawValue) }
        if let frontTrunk { w.writeField(6, frontTrunk.rawValue) }
        return w.data
    }
}

/// VCSEC.UnsignedMessage: RKEAction(2) enum or closureMoveRequest(4) submessage.
func encodeVCSECUnsignedMessage(rkeAction: RKEAction? = nil, closureMove: VCSECClosureMoveRequest? = nil) -> Data {
    var w = ProtobufWriter()
    if let rkeAction, rkeAction.rawValue != 0 { w.writeField(2, rkeAction.rawValue) }
    if let closureMove { w.writeField(4, bytes: closureMove.encoded()) }
    return w.data
}

// MARK: - CarServer.Action subset

/// CarServer.Action{vehicleAction(2){…}} for TesBar's Infotainment command set.
/// Field numbers verified against car_server.proto:
/// hvacAuto=10, hvacTemp=14, preconditioningMax=12, bioweapon=35, seatHeater=36,
/// chargingStartStop=6, setChargingAmps=43, chargingSetLimit=5, flashLights=26,
/// honkHorn=27, sentryMode=30, chargePortDoorOpen=62, chargePortDoorClose=61.
enum CarServerAction: Equatable, Sendable {
    case hvacAuto(powerOn: Bool)
    case hvacOnWithTemperature(celsius: Float)
    case hvacPreconditioningMax(on: Bool)
    case hvacBioweapon(on: Bool)
    case hvacSeatHeater(seat: Seat, level: Int)
    case chargeStart
    case chargeStop
    case chargingAmps(Int32)
    case chargingSetLimit(Int32)
    case chargePortDoorOpen
    case chargePortDoorClose
    case honkHorn
    case flashLights
    case sentryMode(on: Bool)

    enum Seat: Equatable, Sendable { case frontLeft, frontRight }

    func encoded() -> Data {
        var w = ProtobufWriter()
        w.writeField(2) { w in // vehicleAction
            switch self {
            case let .hvacAuto(powerOn):
                w.writeField(10) { $0.writeField(1, bool: powerOn) }
            case let .hvacOnWithTemperature(celsius):
                // Two nested actions in ONE VehicleAction message: hvacAutoAction{on=true}
                // then hvacTemperatureAdjustmentAction — order preserved by field order.
                w.writeField(10) { $0.writeField(1, bool: true) }
                w.writeField(14) { w in
                    w.writeField(6, float: celsius)
                    w.writeField(7, float: celsius)
                }
            case let .hvacPreconditioningMax(on):
                w.writeField(12) { $0.writeField(1, bool: on) }
            case let .hvacBioweapon(on):
                w.writeField(35) { $0.writeField(1, bool: on) }
            case let .hvacSeatHeater(seat, level):
                w.writeField(36) { w in // HvacSeatHeaterActions (repeated=1 entry)
                    w.writeField(1) { w in
                        // Void oneof arms encode as empty submessages.
                        switch level {
                        case 0: w.writeField(2, bytes: Data()) // SEAT_HEATER_OFF
                        case 1: w.writeField(3, bytes: Data()) // SEAT_HEATER_LOW
                        case 2: w.writeField(4, bytes: Data()) // SEAT_HEATER_MED
                        default: w.writeField(5, bytes: Data()) // SEAT_HEATER_HIGH
                        }
                        switch seat {
                        case .frontLeft: w.writeField(7, bytes: Data()) // CAR_SEAT_FRONT_LEFT
                        case .frontRight: w.writeField(8, bytes: Data()) // CAR_SEAT_FRONT_RIGHT
                        }
                    }
                }
            case .chargeStart:
                w.writeField(6) { $0.writeField(2, bytes: Data()) } // charging_action.start (Void)
            case .chargeStop:
                w.writeField(6) { $0.writeField(5, bytes: Data()) } // charging_action.stop (Void)
            case let .chargingAmps(amps):
                w.writeField(43) { $0.writeField(1, UInt32(bitPattern: amps)) }
            case let .chargingSetLimit(percent):
                w.writeField(5) { $0.writeField(1, UInt32(bitPattern: percent)) }
            case .chargePortDoorOpen:
                w.writeField(62, bytes: Data())
            case .chargePortDoorClose:
                w.writeField(61, bytes: Data())
            case .honkHorn:
                w.writeField(27, bytes: Data())
            case .flashLights:
                w.writeField(26, bytes: Data())
            case let .sentryMode(on):
                w.writeField(30) { $0.writeField(1, bool: on) }
            }
        }
        return w.data
    }
}

/// Constant-time Data comparison (used for HMAC tag checks).
func timingSafeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}
