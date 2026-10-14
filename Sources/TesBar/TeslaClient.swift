import Foundation

/// Fake Tesla Fleet API seam: data polling, wake, signed commands, token refresh.
/// Production implementation is FleetTeslaClient (ticket 05); tests inject scripted fakes.
public protocol TeslaClient: Sendable {
    func listVehicles() async throws -> [VehicleListEntry]
    func vehicleData(id: String) async throws -> VehicleSnapshot
    func wake(id: String) async throws
    /// `vehicleID` is the selected vehicle (multi-car story 16); implementations must
    /// resolve it to a VIN, never silently fall back to another vehicle.
    func signAndSend(command: VehicleCommand, vehicleID: String) async throws
    func refreshAccessToken() async throws
}

public struct VehicleListEntry: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    /// 17-char VIN — signed_command is VIN-keyed (ticket 05).
    public let vin: String

    /// Old persisted/test JSON without `vin` decodes with an empty string (union-merge safety);
    /// real Fleet API `GET /api/1/vehicles` responses always carry one.
    public init(id: String, name: String, vin: String = "") {
        self.id = id
        self.name = name
        self.vin = vin
    }

    private enum CodingKeys: String, CodingKey { case id, name, vin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        vin = try c.decodeIfPresent(String.self, forKey: .vin) ?? ""
    }
}

/// Charge / climate / lock / trunk state of one vehicle at one instant.
public struct VehicleSnapshot: Sendable, Equatable, Codable {
    public struct Charge: Sendable, Equatable, Codable {
        /// 0–100.
        public let batteryPercent: Int
        /// Kilometers.
        public let rangeKm: Double
        /// Charging/Stopped/Complete/Disconnected…
        public let state: String
        /// nil unless charging.
        public let minutesToFull: Int?

        public init(batteryPercent: Int, rangeKm: Double, state: String, minutesToFull: Int?) {
            self.batteryPercent = batteryPercent
            self.rangeKm = rangeKm
            self.state = state
            self.minutesToFull = minutesToFull
        }
    }

    public struct Climate: Sendable, Equatable, Codable {
        /// Degrees Celsius, nil while asleep/offline.
        public let insideC: Double?
        public let outsideC: Double?

        public init(insideC: Double?, outsideC: Double?) {
            self.insideC = insideC
            self.outsideC = outsideC
        }
    }

    public struct Doors: Sendable, Equatable, Codable {
        /// nil = 睡眠/离线拉不到 vehicle_state，未知而非"已锁"。
        public let locked: Bool?
        public let frontTrunkOpen: Bool
        public let rearTrunkOpen: Bool

        public init(locked: Bool?, frontTrunkOpen: Bool, rearTrunkOpen: Bool) {
            self.locked = locked
            self.frontTrunkOpen = frontTrunkOpen
            self.rearTrunkOpen = rearTrunkOpen
        }
    }

    public enum State: String, Sendable, Equatable, Codable {
        case online, asleep, offline
    }

    public let charge: Charge
    public let climate: Climate
    public let doors: Doors
    /// Kilometers.
    public let odometerKm: Double
    public let state: State
    /// When the API generated this data (ms since Unix epoch).
    public let timestampMs: Int64

    public init(
        charge: Charge, climate: Climate, doors: Doors,
        odometerKm: Double, state: State, timestampMs: Int64
    ) {
        self.charge = charge
        self.climate = climate
        self.doors = doors
        self.odometerKm = odometerKm
        self.state = state
        self.timestampMs = timestampMs
    }
}

/// One in-app command; each case carries its payload.
/// Sent via ``TeslaClient/signAndSend(command:)`` (wake/online handled upstream, ADR-0001).
public enum VehicleCommand: Sendable, Equatable {
    case hvacOn(temperatureC: Double)
    case hvacOff
    case defrost(on: Bool)
    case horn
    case flashLights
    case sentry(on: Bool)
    case chargePort(open: Bool)
    case startCharge
    case stopCharge
    case setChargeLimit(percent: Int)
    /// 0 = off … 3 = high, seat heater levels.
    case seatHeat(level: Int)
    case unlock
    case lock
    case doorOpen(Door)
    case doorClose(Door)
    case remoteStart
    /// Doors / trunks that count as Dangerous Commands (long-press gate, ADR-0003).
    public enum Door: String, CaseIterable, Sendable, Equatable {
        case frontLeft, frontRight, rearLeft, rearRight, frunk, trunk
    }

    /// True when the 1-second long-press gate applies (ADR-0003).
    public var isDangerous: Bool {
        switch self {
        case .unlock, .doorOpen, .doorClose, .remoteStart: true
        default: false
        }
    }
}

/// 发令失败且属于 VCP 虚拟钥匙未配对（如 UNKNOWN_KEY_ID fault）：车辆拒绝执行任何签名指令。
/// 05 的 FleetTeslaClient 解析到该 fault 时抛出；07 据此给出配对指引而非让用户反复重试。
public struct VirtualKeyNotPairedError: Error, Sendable {
    public init() {}
}
