import CryptoKit
import Foundation
import Testing

@testable import TesBar

/// Vehicle-side VCP responder + scripted fleet/auth HTTP (ticket 05 acceptance).
///
/// The fake vehicle owns a real P-256 keypair, performs real ECDH with the client's
/// public key, and hand-encodes SessionInfo + signature_data like the reference
/// implementation. Suite serialized: shared Keychain service.
@Suite(.serialized)
struct FleetTeslaClientTests {
    static let vin = "5YJ30123456789ABC"
    static let vehicleID = "12345678901234567"
    static let listJSON = #"{"response":[{"id":12345678901234567,"vin":"\#(vin)","display_name":"My Tesla"}]}"#

    // MARK: - Fakes

    /// One scripted fleet-API response.
    enum Reply {
        case message(RoutableMessage)
        /// Live-built fault reply carrying fresh verified session info (recovery path):
        /// tag over the request's uuid, reply echoes it as request_uuid — like the vehicle.
        case faultWithFreshSession(MessageFault)
        case error(status: Int, body: String)
        case json(String)
    }

    /// Fake vehicle: real P-256 key, hand-encoded SessionInfo, real session-info HMAC.
    /// All state is touched only from the serialized test task — no locking.
    final class VehicleSim: @unchecked Sendable {
        let key = try! ECKeyPair.generate()
        var epoch = Data(repeating: 0x4C, count: 16)
        var counter: UInt32 = 6
        let clockTime: UInt32 = 2650

        /// Simulates an infotainment reboot: new epoch, counter jumps forward.
        func reboot() {
            epoch[0] ^= 0xFF
            counter += 10
        }

        /// SessionInfo bytes: counter(1), publicKey(2), epoch(3), clock_time(4 fixed32),
        /// status(5, omitted when OK) — matches Signatures.SessionInfo.
        func sessionInfo(status: UInt32 = 0) -> Data {
            var w = ProtobufWriter()
            w.writeField(1, counter)
            w.writeField(2, bytes: key.publicKeyData)
            w.writeField(3, bytes: epoch)
            w.writeFixed32(4, clockTime)
            if status != 0 { w.writeField(5, status) }
            return w.data
        }

        /// signature_data{ session_info_tag(6){ tag(1) } } with the real HMAC over
        /// TLV(sigType=6, VIN, challenge) || info, keyed with SESSION_INFO_KEY(K).
        func sessionInfoTagWrapper(clientPublicKey: Data, challenge: Data, info: Data) throws -> Data {
            let k = SessionCrypto.sharedKey(fromSecret: try ECKeyPair.sharedSecret(
                privateKey: key.privateKey, peerPublicKey: clientPublicKey))
            let metadata = AuthMetadata(
                signatureType: 6, personalization: Array(FleetTeslaClientTests.vin.utf8),
                challenge: Array(challenge)
            ).serialized
            var signed = metadata
            signed.append(info)
            let tag = Data(HMAC<SHA256>.authenticationCode(
                for: signed, using: SymmetricKey(data: SessionCrypto.sessionInfoKey(k))))
            var w = ProtobufWriter()
            w.writeField(6) { $0.writeField(1, bytes: tag) }
            return w.data
        }

        /// `{"routable_message": "<base64>"}` request body → RoutableMessage.
        static func requestMessage(_ body: Data) throws -> RoutableMessage {
            struct Body: Decodable { let routable_message: String }
            let b64 = try JSONDecoder().decode(Body.self, from: body).routable_message
            guard let data = Data(base64Encoded: b64) else {
                throw FleetError.malformedResponse
            }
            return try RoutableMessage.decode(data)
        }

        /// Client public key out of a command request's signature_data
        /// (KeyIdentity(1){ public_key(1) }).
        static func clientPublicKey(of request: RoutableMessage) throws -> Data {
            var sd = ProtobufReader(try #require(request.signatureData))
            var identity: Data?
            try sd.forEachField { r, f, wt in
                if f == 1, wt == 2 { identity = try r.readBytes() } else { try r.skip(wireType: wt) }
            }
            var idr = ProtobufReader(try #require(identity))
            var pub: Data?
            try idr.forEachField { r, f, wt in
                if f == 1, wt == 2 { pub = try r.readBytes() } else { try r.skip(wireType: wt) }
            }
            return try #require(pub)
        }
    }

    /// Routes token-endpoint requests to the auth script, everything else to the
    /// fleet script; session_info_request replies are built live (need ECDH).
    final class FleetScriptedTransport: HTTPExecuting, @unchecked Sendable {
        struct Call { let url: String; let method: String; let body: Data? }

        private(set) var calls: [Call] = []
        private var authScript: [(status: Int, json: String)]
        private var fleetScript: [Reply]
        private var handshakes: [Reply]  // optional overrides for the handshake reply
        let vehicle: VehicleSim

        init(
            vehicle: VehicleSim,
            auth: [(status: Int, json: String)] = [],
            fleet: [Reply] = [],
            handshakes: [Reply] = []
        ) {
            self.vehicle = vehicle
            self.authScript = auth
            self.fleetScript = fleet
            self.handshakes = handshakes
        }

        func send(_ request: URLRequest) async throws -> (status: Int, headers: [String: String], body: Data) {
            calls.append(Call(
                url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "",
                body: request.httpBody))

            if request.url?.host == "fleet-auth.prd.cn.vn.cloud.tesla.cn" {
                guard let next = authScript.first else { return (500, [:], Data()) }
                authScript.removeFirst()
                return (next.status, ["content-type": "application/json"], Data(next.json.utf8))
            }

            if let body = request.httpBody,
               let msg = try? VehicleSim.requestMessage(body),
               msg.sessionInfoRequestPublicKey != nil
            {
                // Handshake: challenge = the request's uuid(51); the reply echoes it
                // as request_uuid(50) (protocol.md:476; the vehicle never sees field 50).
                let challenge = msg.uuid ?? Data(repeating: 0, count: 16)
                if !handshakes.isEmpty { return Self.dispatch(handshakes.removeFirst()) }
                let info = vehicle.sessionInfo()
                let tag = try vehicle.sessionInfoTagWrapper(
                    clientPublicKey: msg.sessionInfoRequestPublicKey!, challenge: challenge, info: info)
                return Self.messageReply(RoutableMessage(
                    signatureData: tag, sessionInfo: info, requestUUID: challenge))
            }

            if let body = request.httpBody, let msg = try? VehicleSim.requestMessage(body) {
                // Command: check for a live-built recovery fault before the static script.
                if let first = fleetScript.first, case let .faultWithFreshSession(fault) = first {
                    fleetScript.removeFirst()
                    let challenge = msg.uuid ?? Data(repeating: 0, count: 16)
                    let info = vehicle.sessionInfo()
                    let tag = try vehicle.sessionInfoTagWrapper(
                        clientPublicKey: try VehicleSim.clientPublicKey(of: msg),
                        challenge: challenge, info: info)
                    return Self.messageReply(RoutableMessage(
                        signatureData: tag, sessionInfo: info, messageFault: fault,
                        requestUUID: challenge))
                }
            }

            guard let next = fleetScript.first else { return (500, [:], Data("out of script".utf8)) }
            fleetScript.removeFirst()
            return Self.dispatch(next)
        }

        private static func dispatch(_ next: Reply)
            -> (status: Int, [String: String], Data)
        {
            switch next {
            case let .message(m): return Self.messageReply(m)
            case .faultWithFreshSession: return (500, [:], Data("misplaced fault reply".utf8))
            case let .error(status, body):
                return (status, ["content-type": "application/json"], Data(body.utf8))
            case let .json(json):
                return (200, ["content-type": "application/json"], Data(json.utf8))
            }
        }

        private static func messageReply(_ m: RoutableMessage)
            -> (status: Int, [String: String], Data)
        {
            let json = #"{"response":"\#(m.encoded().base64EncodedString())"}"#
            return (200, ["content-type": "application/json"], Data(json.utf8))
        }

        var signedCommandCalls: [Call] { calls.filter { $0.url.contains("/signed_command") } }
    }

    // MARK: - Harness

    /// Fresh client over throwaway Keychain service + fresh UserDefaults suites.
    private func makeClient(
        _ transport: FleetScriptedTransport,
        service: String = "com.tesbar.fleet-tests"
    ) throws -> (client: FleetTeslaClient, store: KeychainStore, suite: String) {
        let suite = "fleet-session-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = KeychainStore(service: service, privateKeyAccount: "fleet-vcp-key")
        let keys = VCPKeyManager(store: store)
        try keys.ensureKeyPair()
        try store.saveToken("at1", for: AuthService.accessAccount)
        try? store.deleteToken(AuthService.refreshAccount)
        let auth = AuthService(clientID: "cid", clientSecret: "s", transport: transport, keychain: store)
        let client = FleetTeslaClient(
            transport: transport, auth: auth,
            resolver: RegionResolver(defaults: UserDefaults(suiteName: "fleet-resolver-\(UUID().uuidString)")!),
            keys: keys, defaults: defaults)
        return (client, store, suite)
    }

    /// Successful empty reply (no fault = accepted).
    static let ok = Reply.message(RoutableMessage())

    private func runCommand(
        _ command: VehicleCommand, service: String = "com.tesbar.fleet-tests"
    ) async throws -> (RoutableMessage, FleetScriptedTransport, VehicleSim) {
        let vehicle = VehicleSim()
        let transport = FleetScriptedTransport(
            vehicle: vehicle, fleet: [.json(Self.listJSON), Self.ok])
        let (client, _, _) = try makeClient(transport, service: service)
        try await client.signAndSend(command: command, vehicleID: Self.vehicleID)
        let calls = transport.signedCommandCalls
        #expect(calls.count == 2)  // handshake + command
        return (try VehicleSim.requestMessage(try #require(calls.last?.body)), transport, vehicle)
    }

    private func countSessionInfoRequests(_ transport: FleetScriptedTransport) throws -> Int {
        var n = 0
        for call in transport.signedCommandCalls {
            if let body = call.body,
               let msg = try? VehicleSim.requestMessage(body),
               msg.sessionInfoRequestPublicKey != nil { n += 1 }
        }
        return n
    }

    // MARK: - listVehicles / vehicleData

    @Test func listVehiclesDecodesRESTJSON() async throws {
        let transport = FleetScriptedTransport(vehicle: VehicleSim(), fleet: [.json(Self.listJSON)])
        let (client, _, _) = try makeClient(transport)

        let list = try await client.listVehicles()
        #expect(list == [VehicleListEntry(id: Self.vehicleID, name: "My Tesla", vin: Self.vin)])
        let call = try #require(transport.calls.first)
        #expect(call.url == "https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles")
        #expect(call.method == "GET" && call.body == nil)
    }

    @Test func vehicleDataMapsRealFleetJSON() async throws {
        let json = """
        {"response":{"state":"online",
          "charge_state":{"battery_level":77,"battery_range":148.2,"charging_state":"Charging","minutes_to_full_charge":45},
          "climate_state":{"inside_temp":21.5,"outside_temp":8.0},
          "vehicle_state":{"locked":true,"ft":0,"rt":1,"odometer":7974.1},
          "timestamp_ms":1760000000000}}
        """
        let transport = FleetScriptedTransport(vehicle: VehicleSim(), fleet: [.json(json)])
        let (client, _, _) = try makeClient(transport)

        let snap = try await client.vehicleData(id: Self.vehicleID)
        #expect(snap.charge.batteryPercent == 77)
        #expect(abs(snap.charge.rangeKm - 148.2 * 1.609344) < 0.01)
        #expect(snap.charge.state == "Charging" && snap.charge.minutesToFull == 45)
        #expect(snap.climate.insideC == 21.5 && snap.climate.outsideC == 8.0)
        #expect(snap.doors.locked == true && !snap.doors.frontTrunkOpen && snap.doors.rearTrunkOpen)
        #expect(abs(snap.odometerKm - 7974.1 * 1.609344) < 0.1)
        #expect(snap.state == .online && snap.timestampMs == 1_760_000_000_000)
        #expect(transport.calls.first?.url.hasSuffix("/vehicle_data") == true)
    }

    @Test func asleepStateMapsFromVehicleState() async throws {
        let json = #"{"response":{"state":"asleep","charge_state":{},"climate_state":{},"vehicle_state":{}}}"#
        let transport = FleetScriptedTransport(vehicle: VehicleSim(), fleet: [.json(json)])
        let (client, _, _) = try makeClient(transport)
        #expect(try await client.vehicleData(id: "x").state == .asleep)
    }

    // MARK: - command → wire mapping

    @Test func lockMapsToVCSECLock() async throws {
        let (msg, _, _) = try await runCommand(.lock)
        #expect(msg.toDomain == .vcsec)
        #expect(msg.flags == 2)
        var rke = try Self.singleVarint(msg.payload!, field: 2)
        #expect(rke == 1)  // RKE_ACTION_LOCK
    }

    @Test func unlockMapsToVCSECUnlock() async throws {
        let (msg, _, _) = try await runCommand(.unlock)
        #expect(msg.toDomain == .vcsec)
        // UNLOCK = 0 → protobuf default → omitted; an empty UnsignedMessage is the
        // wire form of unlock (VCSEC oneof arm RKE_action with default value).
        #expect(msg.payload?.isEmpty == true)
    }

    @Test func trunkOpenMapsToVCSECClosureMove() async throws {
        let (msg, _, _) = try await runCommand(.doorOpen(.trunk))
        #expect(msg.toDomain == .vcsec)
        let closure = try #require(try Self.subMessage(msg.payload!, field: 4))  // closureMoveRequest
        #expect(try Self.singleVarint(closure, field: 5) == 3)  // rear trunk OPEN
    }

    @Test func frunkCloseMapsToFrontTrunkClose() async throws {
        let (msg, _, _) = try await runCommand(.doorClose(.frunk))
        let closure = try #require(try Self.subMessage(msg.payload!, field: 4))
        #expect(try Self.singleVarint(closure, field: 6) == 4)  // front trunk CLOSE
    }

    @Test func wheelDoorsAreRejectedAsUnsupported() async throws {
        let transport = FleetScriptedTransport(
            vehicle: VehicleSim(), fleet: [.json(Self.listJSON)])
        let (client, _, _) = try makeClient(transport)
        await #expect(throws: FleetError.self) {
            try await client.signAndSend(command: .doorOpen(.frontLeft), vehicleID: Self.vehicleID)
        }
        #expect(transport.signedCommandCalls.isEmpty)  // rejected before any POST
    }

    @Test func hvacOnMapsToAutoStartPlusTemperatureBothZones() async throws {
        let (msg, _, _) = try await runCommand(.hvacOn(temperatureC: 21))
        #expect(msg.toDomain == .infotainment)
        #expect(try Self.vehicleActionField(msg.payload!, 10) != Data())  // hvacAuto{on=true}
        let temps = try Self.hvacTemperatures(msg.payload!)
        #expect(temps.driver == 21 && temps.passenger == 21)
    }

    @Test func hvacOffMapsToHvacAutoOff() async throws {
        let (msg, _, _) = try await runCommand(.hvacOff)
        #expect(msg.toDomain == .infotainment)
        // vehicleAction(2){ hvac_auto(10){...} } present (power_on=false omitted: default).
        #expect(try Self.vehicleActionField(msg.payload!, 10) == Data())
    }

    @Test func defrostMapsToPreconditioningMax() async throws {
        let (msg, _, _) = try await runCommand(.defrost(on: true))
        #expect(try Self.vehicleActionField(msg.payload!, 12) == Data([0x08, 0x01]))  // on=true
    }

    @Test func setChargeLimitMapsToChargingSetLimit() async throws {
        let (msg, _, _) = try await runCommand(.setChargeLimit(percent: 80))
        #expect(msg.toDomain == .infotainment)
        let inner = try #require(try Self.vehicleActionField(msg.payload!, 5))
        #expect(try Self.singleVarint(inner, field: 1) == 80)
    }

    @Test func startAndStopChargeMapToChargingActions() async throws {
        let (start, _, _) = try await runCommand(.startCharge)
        #expect(try Self.vehicleActionField(start.payload!, 6) != nil)  // ChargingStartStop
        let (stop, _, _) = try await runCommand(
            .stopCharge, service: "com.tesbar.fleet-tests-2")
        #expect(try Self.vehicleActionField(stop.payload!, 6) != nil)
    }

    @Test func hornAndFlashMapToInfotainment() async throws {
        let (horn, _, _) = try await runCommand(.horn)
        #expect(horn.toDomain == .infotainment)
        #expect(try Self.vehicleActionField(horn.payload!, 27) == Data())  // honk_horn Void
        let (flash, _, _) = try await runCommand(.flashLights, service: "com.tesbar.fleet-tests-2")
        #expect(try Self.vehicleActionField(flash.payload!, 26) == Data())
    }

    @Test func sentryAndChargePortMapToInfotainment() async throws {
        let (sentry, _, _) = try await runCommand(.sentry(on: true))
        #expect(try Self.vehicleActionField(sentry.payload!, 30) == Data([0x08, 0x01]))
        let (port, _, _) = try await runCommand(.chargePort(open: true), service: "com.tesbar.fleet-tests-2")
        #expect(try Self.vehicleActionField(port.payload!, 62) == Data())  // charge_port_door_open
    }

    @Test func seatHeatMapsToFrontLeftHeater() async throws {
        let (msg, _, _) = try await runCommand(.seatHeat(level: 2))
        let heater = try #require(try Self.vehicleActionField(msg.payload!, 36))
        let entry = try #require(try Self.subMessage(heater, field: 1))
        #expect(try Self.subMessage(entry, field: 4) == Data())  // level MED (field 4)
        #expect(try Self.subMessage(entry, field: 7) == Data())  // CAR_SEAT_FRONT_LEFT
        #expect(try Self.subMessage(entry, field: 2) == nil)  // OFF not present
    }

    // MARK: - handshake lifecycle

    @Test func handshakeRunsOnceThenCached() async throws {
        let vehicle = VehicleSim()
        let transport = FleetScriptedTransport(
            vehicle: vehicle, fleet: [.json(Self.listJSON), Self.ok, Self.ok])
        let (client, _, _) = try makeClient(transport)

        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        let bodies = transport.signedCommandCalls.compactMap { $0.body }
        #expect(bodies.count == 3)  // handshake + 2 commands
        #expect(try countSessionInfoRequests(transport) == 1)
        // Counter strictly increases: 6 → 7 (cmd 1) → 8 (cmd 2).
        #expect(try Self.commandCounter(try VehicleSim.requestMessage(bodies[1]).signatureData!) == 7)
        #expect(try Self.commandCounter(try VehicleSim.requestMessage(bodies[2]).signatureData!) == 8)
    }

    @Test func sessionCacheSurvivesNewClientInstance() async throws {
        let vehicle = VehicleSim()
        let transport = FleetScriptedTransport(
            vehicle: vehicle,
            fleet: [.json(Self.listJSON), Self.ok, .json(Self.listJSON), Self.ok])
        let (client, store, suite) = try makeClient(transport)
        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        // Cold start: same UserDefaults + same persisted keypair → no handshake.
        let auth = AuthService(clientID: "cid", clientSecret: "s", transport: transport, keychain: store)
        let client2 = FleetTeslaClient(
            transport: transport, auth: auth,
            resolver: RegionResolver(defaults: UserDefaults(suiteName: "fleet-resolver-\(UUID().uuidString)")!),
            keys: VCPKeyManager(store: store), defaults: UserDefaults(suiteName: suite)!)
            try await client2.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        // handshake + command + (cold client) command: 3 posts, ONE handshake —
        // the persisted session (UserDefaults + keypair) survives the new instance.
        #expect(transport.signedCommandCalls.count == 3)
        #expect(try countSessionInfoRequests(transport) == 1)
        // K re-derived from ECDH on the cold path: command 2 still authenticates.
        #expect(try Self.commandCounter(
            try VehicleSim.requestMessage(try #require(transport.signedCommandCalls[2].body)).signatureData!) == 8)
    }

    // MARK: - faults and recovery

    @Test func unknownKeyIDFaultThrowsVirtualKeyNotPaired() async throws {
        let transport = FleetScriptedTransport(
            vehicle: VehicleSim(),
            fleet: [.json(Self.listJSON), .message(RoutableMessage(messageFault: .unknownKeyID))])
        let (client, _, _) = try makeClient(transport)
        await #expect(throws: VirtualKeyNotPairedError.self) {
            try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        }
    }

    @Test func sessionInfoStatusNotOnWhitelistThrowsVirtualKeyNotPaired() async throws {
        let vehicle = VehicleSim()
        // Handshake reply carrying status=1 (KEY_NOT_ON_WHITELIST): the client checks
        // status before caching (Go GetError), so nothing is paired.
        let reply = RoutableMessage(
            signatureData: try vehicle.sessionInfoTagWrapper(  // any decodable field-6 tag wrapper
                clientPublicKey: vehicle.key.publicKeyData, challenge: Data(repeating: 0, count: 16),
                info: vehicle.sessionInfo(status: 1)),
            sessionInfo: vehicle.sessionInfo(status: 1))
        let transport = FleetScriptedTransport(
            vehicle: vehicle, fleet: [.json(Self.listJSON)], handshakes: [.message(reply)])
        let (client, _, _) = try makeClient(transport)
        await #expect(throws: VirtualKeyNotPairedError.self) {
            try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        }
    }

    @Test func faultWithoutSessionInfoIsVehicleRejected() async throws {
        let transport = FleetScriptedTransport(
            vehicle: VehicleSim(),
            fleet: [.json(Self.listJSON), .message(RoutableMessage(messageFault: .incorrectEpoch))])
        let (client, _, _) = try makeClient(transport)
        do {
            try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
            Issue.record("expected vehicleRejected")
        } catch let e as FleetError {
            guard case .vehicleRejected = e else {
                Issue.record("got \(e)")
                return
            }
        }
    }

    @Test func incorrectEpochFaultWithFreshSessionInfoRetriesOnce() async throws {
        let vehicle = VehicleSim()
        let transport = FleetScriptedTransport(
            vehicle: vehicle,
            fleet: [.json(Self.listJSON), Self.ok, .faultWithFreshSession(.incorrectEpoch), Self.ok])
        let (client, _, _) = try makeClient(transport)
        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        // Vehicle reboots: new epoch, counter 6→16.
        vehicle.reboot()
        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        // The client can't know the epoch died until the fault arrives: cmd 2 goes
        // out on the stale session, the fault's fresh session info covers the one
        // retry. handshake + cmd1 + faulted cmd2 + retry = 4 posts, one handshake.
        #expect(transport.signedCommandCalls.count == 4)
        #expect(try countSessionInfoRequests(transport) == 1)

        let bodies = transport.signedCommandCalls.compactMap { $0.body }
        let retry = try VehicleSim.requestMessage(bodies[3])
    }

    // MARK: - HTTP status mapping

    @Test func protocolUnsupported422() async throws {
        let transport = FleetScriptedTransport(
            vehicle: VehicleSim(),
            fleet: [.json(Self.listJSON), .error(status: 422, body: "{}")])
        let (client, _, _) = try makeClient(transport)
        await #expect(throws: FleetError.protocolUnsupported) {
            try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        }
    }

    @Test func asleep503AndOffline408() async throws {
        let transport = FleetScriptedTransport(
            vehicle: VehicleSim(),
            fleet: [.json(Self.listJSON), .error(status: 503, body: "{}")])
        let (client, _, _) = try makeClient(transport)
        await #expect(throws: FleetError.vehicleNotAwake) {
            try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        }

        let transport2 = FleetScriptedTransport(
            vehicle: VehicleSim(),
            fleet: [.json(Self.listJSON), .error(status: 408, body: #"{"error":"vehicle is offline"}"#)])
        let (client2, _, _) = try makeClient(transport2, service: "com.tesbar.fleet-tests-2")
        await #expect(throws: FleetError.vehicleNotAwake) {
            try await client2.signAndSend(command: .lock, vehicleID: Self.vehicleID)
        }
    }

    @Test func unauthorized401RefreshesAndRetries() async throws {
        let vehicle = VehicleSim()
        let transport = FleetScriptedTransport(
            vehicle: vehicle,
            auth: [(status: 200, json: #"{"access_token":"at2","refresh_token":"rt2","expires_in":28800}"#)],
            fleet: [.json(Self.listJSON), Self.ok],
            handshakes: [.error(status: 401, body: "{}")])  // handshake POST 401 → refresh → live retry
        let (client, store, _) = try makeClient(transport)
        try store.saveToken("rt1", for: AuthService.refreshAccount)

        try await client.signAndSend(command: .lock, vehicleID: Self.vehicleID)

        #expect(try store.readToken(AuthService.refreshAccount) == "rt2")
        #expect(try store.readToken(AuthService.accessAccount) == "at2")
        #expect(transport.calls.contains { $0.url.contains("oauth2/v3/token") })
        // authorized() re-ran the whole body after refresh: faulted handshake POST,
        // live handshake POST, command POST.
        #expect(transport.signedCommandCalls.count == 3)
    }

    // MARK: - payload field helpers

    /// First varint value of `field` in a protobuf message (nil when absent).
    static func singleVarint(_ data: Data, field: Int) throws -> UInt32? {
        var r = ProtobufReader(data)
        var out: UInt32?
        try r.forEachField { r, f, wt in
            if f == field, wt == 0 { out = try r.readUInt32() } else { try r.skip(wireType: wt) }
        }
        return out
    }

    /// First length-delimited submessage bytes of `field` (nil when absent).
    static func subMessage(_ data: Data, field: Int) throws -> Data? {
        var r = ProtobufReader(data)
        var out: Data?
        try r.forEachField { r, f, wt in
            if f == field, wt == 2 { out = try r.readBytes() } else { try r.skip(wireType: wt) }
        }
        return out
    }

    /// CarServer.Action{vehicleAction(2)} → the given sub-field of vehicleAction.
    static func vehicleActionField(_ payload: Data, _ field: Int) throws -> Data? {
        try subMessage(try #require(try subMessage(payload, field: 2)), field: field)
    }

    static func hvacTemperatures(_ payload: Data) throws -> (driver: Float, passenger: Float) {
        let hvac = try #require(try vehicleActionField(payload, 14))
        var r = ProtobufReader(hvac)
        var d: Float = 0, p: Float = 0
        try r.forEachField { r, f, wt in
            switch (f, wt) {
            case (6, 5): d = try r.readFloat()
            case (7, 5): p = try r.readFloat()
            default: try r.skip(wireType: wt)
            }
        }
        return (d, p)
    }

    /// SignatureData → HMAC_PERSONALIZED(8){ counter(2) / epoch(1) }.
    static func commandCounter(_ signatureData: Data) throws -> UInt32 {
        let hmac = try #require(try subMessage(signatureData, field: 8))
        return try #require(try singleVarint(hmac, field: 2))
    }

    static func commandEpoch(_ signatureData: Data) throws -> Data {
        let hmac = try #require(try subMessage(signatureData, field: 8))
        return try #require(try subMessage(hmac, field: 1))
    }
}
