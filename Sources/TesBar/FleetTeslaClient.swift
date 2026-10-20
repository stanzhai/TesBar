import Foundation
import Security
import os

public enum FleetError: Error, Equatable, Sendable {
    /// HTTP 422 — vehicle/fleet does not support the VCP signed_command protocol.
    case protocolUnsupported
    /// Vehicle asleep or offline (HTTP 503, or 408 + "vehicle is offline").
    case vehicleNotAwake
    /// Application-layer message fault with no more-specific mapping (carries the fault name).
    case vehicleRejected(String)
    /// Command has no Tesla counterpart (e.g. opening an individual door).
    case unsupportedCommand(String)
    /// Signed command sent before any vehicle was listed (no VIN to route to).
    case noVehicle
    /// Handshake reply did not verify or a reply body was malformed.
    case malformedResponse
}

/// Production `TeslaClient` over the Fleet API (ticket 05).
///
/// - Data endpoints are vehicle-id-keyed REST JSON; commands go to
///   `POST /api/1/vehicles/{vin}/signed_command` with a VCP-authenticated protobuf body
///   (VCSEC = 2, Infotainment = 3), built on ticket 12's `SessionCrypto`.
/// - Every HTTP call runs inside `AuthService.authorized` (401 → refresh → retry once,
///   ticket 04); the transport is `RegionRedirectTransport` (421 + Alt-Svc retry, ticket 08).
public actor FleetTeslaClient: TeslaClient {
    private let transport: any HTTPExecuting
    private let auth: AuthService
    private let resolver: RegionResolver
    private let keys: VCPKeyManager
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.tesbar.app", category: "fleet-client")
    /// Per-VIN session managers. Sessions persist to UserDefaults; this map is only the
    /// in-process warm cache of managers.
    private var sessionManagers: [String: VCPSessionManager] = [:]
    /// id → vin from the last listVehicles (``TeslaClient/signAndSend(command:vehicleID:)``
    /// is id-keyed; misses re-list).
    private var vins: [String: String] = [:]
    /// Random per-client routing address (Go: d.address).
    private let routingAddress = FleetTeslaClient.randomBytes(16)

    public init(
        transport: any HTTPExecuting,
        auth: AuthService,
        resolver: RegionResolver,
        keys: VCPKeyManager = VCPKeyManager(),
        defaults: UserDefaults = .standard
    ) {
        self.transport = transport
        self.auth = auth
        self.resolver = resolver
        self.keys = keys
        self.defaults = defaults
    }

    // MARK: TeslaClient — REST data endpoints

    public func listVehicles() async throws -> [VehicleListEntry] {
        struct Response: Decodable {
            struct Entry: Decodable {
                let id: Int64
                let vin: String
                let displayName: String?
                let state: String?
                enum CodingKeys: String, CodingKey {
                    case id, vin, state
                    case displayName = "display_name"
                }
            }
            let response: [Entry]
        }
        let json = try await get(path: "/api/1/vehicles")
        let entries = try JSONDecoder()
            .decode(Response.self, from: json)
            .response
            .map {
                VehicleListEntry(
                    id: String($0.id),
                    name: $0.displayName ?? $0.vin,
                    vin: $0.vin,
                    state: $0.state ?? ""
                )
            }
        vins = Dictionary(entries.map { ($0.id, $0.vin) }, uniquingKeysWith: { a, _ in a })
        return entries
    }

    public func vehicleData(id: String) async throws -> VehicleSnapshot {
        // endpoints 选择器：停放时 drive_state 不含坐标，需显式请求 location_data
        //（tesla-api#786）。授权未含 vehicle_location scope 时整请求 403 →
        // 降级重发（无位置，但电量/温度等照常），失败原因记入 positionError 供异常卡展示。
        do {
            return try VehicleSnapshotMapper.map(try await get(
                path: "/api/1/vehicles/\(id)/vehicle_data",
                query: [("endpoints", "location_data;charge_state;climate_state;drive_state;vehicle_state")]
            ))
        } catch let e as HTTPStatusError where e.status == 403 {
            var snap = try VehicleSnapshotMapper.map(try await get(
                path: "/api/1/vehicles/\(id)/vehicle_data",
                query: [("endpoints", "charge_state;climate_state;drive_state;vehicle_state")]
            ))
            snap.positionError = e.body.map { body in
                body.contains("vehicle_location")
                    ? "缺少位置权限（vehicle_location scope）。请退出登录后重新登录，授权时勾选位置权限。"
                    : body
            }
            return snap
        }
    }

    /// REST wake (not VCSEC RKE_ACTION_WAKE): a REST state comes back that pollers can
    /// re-read, matching ``CommandExecutor``'s ensureAwake loop (ticket 07 contract).
    public func wake(id: String) async throws {
        _ = try await post(path: "/api/1/vehicles/\(id)/wake_up")
    }

    public func refreshAccessToken() async throws {
        try await auth.ensureFreshAccessToken()
    }

    // MARK: TeslaClient — signed commands

    public func signAndSend(command: VehicleCommand, vehicleID: String) async throws {
        guard let vin = try await vin(for: vehicleID) else { throw FleetError.noVehicle }
        let (domain, payload) = try encode(command)
        let manager = sessionManager(vin: vin)

        // No cached session for this domain → handshake first (research §2 step 1).
        if manager.record(domain) == nil {
            try await handshake(domain: domain, vin: vin, manager: manager)
        }
        switch try await attempt(domain: domain, payload: payload, vin: vin, manager: manager) {
        case .success:
            return
        case let .failed(fault):
            throw FleetError.vehicleRejected(fault)
        case .retryWithNewSession:
            // process() already stored the fault's verified fresh session; one retry only.
            logger.info("retrying once on session-update fault (domain \(domain.rawValue))")
            switch try await attempt(domain: domain, payload: payload, vin: vin, manager: manager) {
            case .success: return
            case let .failed(fault): throw FleetError.vehicleRejected(fault)
            case .retryWithNewSession: throw FleetError.malformedResponse
            }
        }
    }

    private enum CommandOutcome {
        case success
        case retryWithNewSession
        case failed(String)
    }

    private func attempt(
        domain: VCPDomain, payload: Data, vin: String, manager: VCPSessionManager
    ) async throws -> CommandOutcome {
        let privateKey = try keys.loadPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let clientPublicKey = try? ECKeyPair.encodePublicKey(publicKey)
        else { throw FleetError.malformedResponse }
        guard let counter = manager.nextCounter(domain),
              let session = try manager.session(domain, clientPrivateKey: privateKey)
        else { throw FleetError.malformedResponse }
        let expiresAt = (manager.vehicleSeconds(domain) ?? 0) + 5 // Go defaultExpiration
        let bytes = SessionCrypto.authenticatedCommand(
            payload: payload, domain: domain, vin: vin, session: session,
            clientPublicKey: clientPublicKey, uuid: Self.randomBytes(16),
            routingAddress: routingAddress, expiresAt: expiresAt, counter: counter)
        let reply = try await sendSignedCommand(bytes, vin: vin)
        return try process(reply: reply, domain: domain, manager: manager, privateKey: privateKey)
    }

    /// Maps a command reply: fault → error (UNKNOWN_KEY_ID → pairing guidance per ticket 07);
    /// a session-update fault carrying a fresh verified session_info → one retry.
    private func process(
        reply: RoutableMessage, domain: VCPDomain, manager: VCPSessionManager,
        privateKey: SecKey
    ) throws -> CommandOutcome {
        guard let fault = reply.messageFault else {
            return .success // OPERATIONSTATUS_OK: no fault = vehicle accepted
        }
        switch fault {
        case .errorNone:
            return .success
        case .unknownKeyID:
            throw VirtualKeyNotPairedError()
        case .invalidTokenOrCounter, .incorrectEpoch:
            guard let info = reply.sessionInfo, let signatureData = reply.signatureData,
                  let tag = try? SignatureDataTag.decode(signatureData).sessionInfoTag,
                  reply.requestUUID != nil,
                  (try manager.processHello(
                      domain: domain, sessionInfoBytes: info, tag: tag,
                      challenge: reply.requestUUID!, clientPrivateKey: privateKey)) != nil
            else { return .failed(String(describing: fault)) }
            return .retryWithNewSession
        default:
            return .failed(String(describing: fault))
        }
    }

    // MARK: Handshake

    /// session_info_request → session_info: verifies the HMAC tag against
    /// K = SHA1(ECDH(client, vehicle)) and caches the session (VCPSessionManager).
    private func handshake(domain: VCPDomain, vin: String, manager: VCPSessionManager) async throws {
        let privateKey = try keys.loadPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let clientPublicKey = try? ECKeyPair.encodePublicKey(publicKey)
        else { throw FleetError.malformedResponse }
        let uuid = Self.randomBytes(16)
        // Go Send(): the challenge is the request's uuid (field 51); the vehicle echoes
        // it back as the reply's request_uuid (50). requestUUID is never set on requests.
        let message = RoutableMessage(
            toDomain: domain, fromRoutingAddress: routingAddress,
            sessionInfoRequestPublicKey: clientPublicKey, uuid: uuid, flags: 2
        ).encoded()
        let reply = try await sendSignedCommand(message, vin: vin)
        if let fault = reply.messageFault {
            manager.invalidate(domain)
            if fault == .unknownKeyID { throw VirtualKeyNotPairedError() }
            throw FleetError.vehicleRejected(String(describing: fault))
        }
        guard let info = reply.sessionInfo, let signatureData = reply.signatureData,
              let tag = try? SignatureDataTag.decode(signatureData).sessionInfoTag
        else { throw FleetError.malformedResponse }
        // Go GetError maps SessionInfo.status = 1 (KEY_NOT_ON_WHITELIST) to a
        // pairing-required error before anything is cached.
        if let status = try? SessionInfo.decode(info).status, status == 1 {
            throw VirtualKeyNotPairedError()
        }
        guard (try manager.processHello(
            domain: domain, sessionInfoBytes: info, tag: tag, challenge: uuid,
            clientPrivateKey: privateKey)) != nil
        else { throw FleetError.malformedResponse }
    }

    private func sessionManager(vin: String) -> VCPSessionManager {
        if let manager = sessionManagers[vin] { return manager }
        let manager = VCPSessionManager(vin: vin, defaults: defaults)
        sessionManagers[vin] = manager
        return manager
    }

    /// VIN for the selected vehicle id (multi-car story 16); refreshes the id→vin map
    /// from a fresh list on miss instead of guessing another vehicle.
    private func vin(for vehicleID: String) async throws -> String? {
        if let vin = vins[vehicleID] { return vin }
        return try await listVehicles().first(where: { $0.id == vehicleID })?.vin
    }

    // MARK: VehicleCommand → domain + protobuf payload

    /// Trunk/frunk actuation is VCSEC ClosureMoveRequest; individual wheel doors have no
    /// Tesla command (research §5).
    private func encode(_ command: VehicleCommand) throws -> (VCPDomain, Data) {
        switch command {
        // VCSEC
        case .lock:
            return (.vcsec, encodeVCSECUnsignedMessage(rkeAction: .lock))
        case .unlock:
            return (.vcsec, encodeVCSECUnsignedMessage(rkeAction: .unlock))
        case .remoteStart:
            return (.vcsec, encodeVCSECUnsignedMessage(rkeAction: .remoteDrive))
        case .doorOpen(.trunk):
            return (.vcsec, encodeVCSECUnsignedMessage(
                closureMove: VCSECClosureMoveRequest(frontTrunk: nil, rearTrunk: .open)))
        case .doorClose(.trunk):
            return (.vcsec, encodeVCSECUnsignedMessage(
                closureMove: VCSECClosureMoveRequest(frontTrunk: nil, rearTrunk: .close)))
        case .doorOpen(.frunk):
            return (.vcsec, encodeVCSECUnsignedMessage(
                closureMove: VCSECClosureMoveRequest(frontTrunk: .open, rearTrunk: nil)))
        case .doorClose(.frunk):
            return (.vcsec, encodeVCSECUnsignedMessage(
                closureMove: VCSECClosureMoveRequest(frontTrunk: .close, rearTrunk: nil)))
        case .doorOpen, .doorClose:
            throw FleetError.unsupportedCommand("individual doors cannot be actuated remotely")
        // Infotainment
        case .hvacOn:
            // research §5: auto_conditioning_start → hvacAutoAction.powerOn.
            return (.infotainment, CarServerAction.hvacAuto(powerOn: true).encoded())
        case .hvacOff:
            return (.infotainment, CarServerAction.hvacAuto(powerOn: false).encoded())
        case let .defrost(on):
            return (.infotainment, CarServerAction.hvacPreconditioningMax(on: on).encoded())
        case .horn:
            return (.infotainment, CarServerAction.honkHorn.encoded())
        case .flashLights:
            return (.infotainment, CarServerAction.flashLights.encoded())
        case let .sentry(on):
            return (.infotainment, CarServerAction.sentryMode(on: on).encoded())
        case let .chargePort(open):
            let action: CarServerAction = open ? .chargePortDoorOpen : .chargePortDoorClose
            return (.infotainment, action.encoded())
        case .startCharge:
            return (.infotainment, CarServerAction.chargeStart.encoded())
        case .stopCharge:
            return (.infotainment, CarServerAction.chargeStop.encoded())
        case let .setChargeLimit(percent):
            return (.infotainment, CarServerAction.chargingSetLimit(Int32(percent)).encoded())
        case let .seatHeat(level):
            return (.infotainment, CarServerAction.hvacSeatHeater(seat: .frontLeft, level: level).encoded())
        }
    }

    // MARK: HTTP plumbing

    /// Wraps a command POST in ``AuthService/authorized(_:)`` (401 → refresh → retry).
    /// Status mapping runs inside the wrapper so a 401 surfaces as `HTTPStatusError`
    /// there and triggers refresh+retry (Go inet.go semantics).
    private func sendSignedCommand(_ bytes: Data, vin: String) async throws -> RoutableMessage {
        struct Body: Encodable { let routable_message: String }
        let json = try JSONEncoder().encode(Body(routable_message: bytes.base64EncodedString()))
        let r = try await withPartnerRegistration {
            try await self.auth.authorized {
                let r = try await self.send(path: "/api/1/vehicles/\(vin)/signed_command", body: json)
                _ = try Self.mapStatus(r.status, r.body)
                return r
            }
        }
        return try decodeSignedResponse(status: r.status, body: r.body)
    }

    private func get(path: String, query: [(String, String)] = []) async throws -> Data {
        let r = try await withPartnerRegistration {
            try await self.auth.authorized { try await self.send(path: path, query: query, body: nil) }
        }
        _ = try Self.mapStatus(r.status, r.body)
        return r.body
    }

    private func post(path: String) async throws -> Data {
        let r = try await withPartnerRegistration {
            try await self.auth.authorized { try await self.send(path: path, body: Data("{}".utf8)) }
        }
        _ = try Self.mapStatus(r.status, r.body)
        return r.body
    }
    /// China conventions: 412 = account not registered → register via
    /// `POST /api/1/partner_accounts` (partner token) and retry the call once.
    /// The endpoint resolves the key-hosting domain from the app's allowed_origins
    /// (developer portal); we also send the pairing domain when configured.
    private func withPartnerRegistration(
        _ call: @Sendable () async throws -> (status: Int, headers: [String: String], body: Data)
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        let first = try await call()
        guard first.status == 412 else { return first }
        logger.notice("412 — registering partner account, then retrying once")
        let token = try await auth.partnerAccessToken()
        var request = URLRequest(url: resolver.baseURL.appendingPathComponent("/api/1/partner_accounts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let domain = defaults.string(forKey: "tesbarPairingDomain"),
           !domain.trimmingCharacters(in: .whitespaces).isEmpty {
            struct Body: Encodable { let domain: String }
            request.httpBody = try? JSONEncoder().encode(
                Body(domain: domain.trimmingCharacters(in: .whitespaces)))
        }
        let registration = try await transport.send(request)
        if !(200...299).contains(registration.status) {
            let snippet = Self.bodySnippet(registration.body) ?? "<empty body>"
            logger.error("partner_accounts registration → \(registration.status): \(snippet)")
            let hint = registration.status == 400
                ? "（域名未在 developer.tesla.cn 的 allowed_origins 配置，或该域名未托管 /.well-known/appspecific/com.tesla.3p.public-key.pem 公钥）"
                : ""
            throw HTTPStatusError(412, body: "账户注册失败（\(registration.status)）：\(snippet)\(hint)")
        }
        logger.notice("partner account registered")
        return try await call()
    }

    /// One request out through the region-aware transport; no status check here — callers
    /// map statuses (throwing `HTTPStatusError` makes `authorized` retry 401s).
    private func send(path: String, query: [(String, String)] = [], body: Data?) async throws
        -> (status: Int, headers: [String: String], body: Data)
    {
        let base = resolver.baseURL
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents 保留 ; 原样（合法 pchar），Tesla 的 endpoints 选择器要求
            // 分号编码为 %3B——裸 ; 会被服务器当成只传了第一个 endpoint
            //（实测只返回 drive_state，其余字段静默缺失）。
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: ";", with: "%3B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try? await auth.currentAccessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let r = try await transport.send(request)
        if !(200...299).contains(r.status) {
            // One line per failed call — `log show` is the only telemetry this app has.
            logger.error("Fleet API \(request.httpMethod ?? "GET") \(path) → \(r.status) via \(base.host ?? "?"): \(Self.bodySnippet(r.body) ?? "<empty body>")")
        }
        return r
    }

    /// `{"response": "<base64>"}` → RoutableMessage.
    private func decodeSignedResponse(status: Int, body: Data) throws -> RoutableMessage {
        struct Response: Decodable { let response: String }
        let base64 = try JSONDecoder().decode(Response.self, from: body).response
        guard let data = Data(base64Encoded: base64) else { throw FleetError.malformedResponse }
        return try RoutableMessage.decode(data)
    }

    /// Go inet.go status map: 422 protocol-unsupported, 503 asleep,
    /// 408 + "vehicle is offline" asleep; other non-OK surfaces as `HTTPStatusError`
    /// (401 feeds the authorized() retry). The body snippet rides along so the UI
    /// shows the server's own message instead of a bare type name.
    private static func mapStatus(_ status: Int, _ body: Data) throws {
        switch status {
        case 200: return
        case 422: throw FleetError.protocolUnsupported
        case 503: throw FleetError.vehicleNotAwake
        case 408 where body.range(of: Data("vehicle is offline".utf8)) != nil:
            throw FleetError.vehicleNotAwake
        default: throw HTTPStatusError(status, body: Self.bodySnippet(body))
        }
    }

    /// Response body trimmed to a one-line snippet; JSON `error_description` wins when present.
    static func bodySnippet(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for key in ["error_description", "error", "message"] {
                if let value = json[key] as? String { return String(value.prefix(200)) }
            }
        }
        return String(text.split(separator: "\n").first ?? "").prefix(200).description
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

/// `signature_data` session_info_tag arm (oneof field 6: HMAC_Signature_Data{tag(1)}).
struct SignatureDataTag: Equatable, Sendable {
    let sessionInfoTag: Data

    static func decode(_ data: Data) throws -> SignatureDataTag {
        var reader = ProtobufReader(data)
        var tag: Data?
        try reader.forEachField { reader, field, wireType in
            if field == 6, wireType == 2 {
                var inner = ProtobufReader(try reader.readBytes())
                try inner.forEachField { inner, f, wt in
                    if f == 1, wt == 2 { tag = try inner.readBytes() } else { try inner.skip(wireType: wt) }
                }
            } else {
                try reader.skip(wireType: wireType)
            }
        }
        guard let tag else { throw FleetError.malformedResponse }
        return SignatureDataTag(sessionInfoTag: tag)
    }
}

/// Fleet API `GET /vehicle_data` JSON → `VehicleSnapshot` (research §1 field names;
/// Fleet API reports miles, TesBar stores kilometers).
enum VehicleSnapshotMapper {
    static func map(_ json: Data) throws -> VehicleSnapshot {
        struct Response: Decodable { let response: Payload }

        struct Payload: Decodable {
            let state: String?
            let chargeState: ChargeState?
            let climateState: ClimateState?
            let vehicleState: VehicleState?
            let driveState: DriveState?
            // vehicle_data 用 "timestamp"；telemetry 用 "timestamp_ms"。两个都收。
            let timestamp: Int64?
            let timestampMsRaw: Int64?
            enum CodingKeys: String, CodingKey {
                case state
                case chargeState = "charge_state"
                case climateState = "climate_state"
                case vehicleState = "vehicle_state"
                case driveState = "drive_state"
                case timestampMsRaw = "timestamp_ms"
                case timestamp
            }
            var timestampMs: Int64? { timestampMsRaw ?? timestamp }
            struct ChargeState: Decodable {
                let batteryLevel: Int?
                let batteryRange: Double?
                let chargingState: String?
                let minutesToFullCharge: Int?
                enum CodingKeys: String, CodingKey {
                    case batteryLevel = "battery_level"
                    case batteryRange = "battery_range"
                    case chargingState = "charging_state"
                    case minutesToFullCharge = "minutes_to_full_charge"
                }
            }
            struct ClimateState: Decodable {
                let insideTemp: Double?
                let outsideTemp: Double?
                let isClimateOn: Bool?
                enum CodingKeys: String, CodingKey {
                    case insideTemp = "inside_temp"
                    case outsideTemp = "outside_temp"
                    case isClimateOn = "is_climate_on"
                }
            }
            struct VehicleState: Decodable {
                let locked: Bool?
                let sentryMode: Bool?
                let ft: Int?
                let rt: Int?
                let odometer: Double?
                enum CodingKeys: String, CodingKey {
                    case locked
                    case sentryMode = "sentry_mode"
                    case ft, rt, odometer
                }
            }
            struct DriveState: Decodable {
                /// P = parked, D/R/N = moving, nil = 未上报（睡眠时无 drive_state）。
                let shiftState: String?
                let latitude: Double?
                let longitude: Double?
                /// 中国区 GCJ-02 坐标（native_type=gcj）：Apple Maps 中国底图是 GCJ，
                /// 用 WGS 的 latitude/longitude 会偏 ~500m。优先取 native。
                let nativeLatitude: Double?
                let nativeLongitude: Double?
                enum CodingKeys: String, CodingKey {
                    case shiftState = "shift_state"
                    case latitude
                    case longitude
                    case nativeLatitude = "native_latitude"
                    case nativeLongitude = "native_longitude"
                }
            }
        }

        let p = try JSONDecoder().decode(Response.self, from: json).response
        let state: VehicleSnapshot.State = switch p.state {
        case "online": .online
        case "asleep": .asleep
        default: .offline
        }
        return VehicleSnapshot(
            charge: .init(
                batteryPercent: p.chargeState?.batteryLevel ?? 0,
                rangeKm: (p.chargeState?.batteryRange ?? 0) * 1.609344, // miles → km
                state: p.chargeState?.chargingState ?? "unknown",
                minutesToFull: p.chargeState?.minutesToFullCharge),
            climate: .init(
                insideC: p.climateState?.insideTemp, outsideC: p.climateState?.outsideTemp,
                hvacOn: p.climateState?.isClimateOn),
            doors: .init(
                locked: p.vehicleState?.locked,
                frontTrunkOpen: (p.vehicleState?.ft ?? 0) != 0,
                rearTrunkOpen: (p.vehicleState?.rt ?? 0) != 0,
                sentryOn: p.vehicleState?.sentryMode),
            odometerKm: (p.vehicleState?.odometer ?? 0) * 1.609344,
            state: state,
            // 行驶中 = drive_state.shift_state 有值且不是 P（睡眠时无 drive_state → false）。
            driving: p.driveState.map { $0.shiftState.map { !$0.isEmpty && $0 != "P" } ?? false } ?? false,
            position: p.driveState.flatMap { d in
                // GCJ 优先（Apple Maps 中国底图同坐标系）；非中国无 native 字段退 WGS。
                if let lat = d.nativeLatitude, let lon = d.nativeLongitude {
                    return .init(latitude: lat, longitude: lon)
                }
                guard let lat = d.latitude, let lon = d.longitude else { return nil }
                return .init(latitude: lat, longitude: lon)
            },
            timestampMs: p.timestampMs ?? 0
        )
    }
}
