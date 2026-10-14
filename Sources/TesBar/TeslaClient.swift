import Foundation

/// Fake Tesla Fleet API seam: data polling, wake, signed commands, token refresh.
/// Production implementation is FleetTeslaClient (ticket 05); tests inject scripted fakes.
public protocol TeslaClient: Sendable {
    func listVehicles() async throws -> [VehicleListEntry]
    func vehicleData(id: String) async throws -> VehicleSnapshot
    func wake(id: String) async throws
    func signAndSend(command: VehicleCommand) async throws
    func refreshAccessToken() async throws
}

public struct VehicleListEntry: Sendable, Equatable, Codable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
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
        public let locked: Bool
        public let anyOpen: Bool
        public let frontTrunkOpen: Bool
        public let rearTrunkOpen: Bool

        public init(locked: Bool, anyOpen: Bool, frontTrunkOpen: Bool, rearTrunkOpen: Bool) {
            self.locked = locked
            self.anyOpen = anyOpen
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
    public enum Door: String, Sendable, Equatable {
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
