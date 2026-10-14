import Foundation

/// 唯一测试接缝：Fleet API 数据 + 指令 + 认证的门面。
public protocol TeslaClient: Sendable {
    func listVehicles() async throws -> [VehicleListEntry]
    func vehicleData(id: String) async throws -> VehicleSnapshot
    func wake(id: String) async throws
    func signAndSend(command: VehicleCommand) async throws
    func refreshAccessToken() async throws
}

/// 指令 payload 枚举（spec「指令」分组）。
public enum VehicleCommand: Sendable, Equatable {
    case climate(on: Bool, driverTempC: Double? = nil)
    case defrost(on: Bool)
    case honk
    case flashLights
    case sentry(on: Bool)
    case chargePort(open: Bool)
    case charging(start: Bool)
    case chargeLimit(percent: Int)
    case seatHeat(driver: Bool? = nil)
    // Dangerous Command（长按确认 + 可选门禁）
    case unlock
    case lock
    case door(open: Bool)
    case trunk(open: Bool)
    case frunk(open: Bool)
    case remoteStart
}

public struct VehicleListEntry: Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 一次车辆数据快照：电量、续航、充电、温度、门窗/锁/后备箱、里程、在线/睡眠、时间戳。
public struct VehicleSnapshot: Sendable, Equatable {
    public let batteryPercent: Int
    public let rangeKm: Double
    public let isCharging: Bool
    public let minutesToFull: Int?
    public let insideTempC: Double?
    public let outsideTempC: Double?
    public let doorsOpen: Bool
    public let windowsOpen: Bool
    public let isLocked: Bool
    public let trunkOpen: Bool
    public let odometerKm: Double
    public let isOnline: Bool
    public let isAsleep: Bool
    public let timestamp: Date
    public init(
        batteryPercent: Int,
        rangeKm: Double,
        isCharging: Bool,
        minutesToFull: Int?,
        insideTempC: Double?,
        outsideTempC: Double?,
        doorsOpen: Bool,
        windowsOpen: Bool,
        isLocked: Bool,
        trunkOpen: Bool,
        odometerKm: Double,
        isOnline: Bool,
        isAsleep: Bool,
        timestamp: Date
    ) {
        self.batteryPercent = batteryPercent
        self.rangeKm = rangeKm
        self.isCharging = isCharging
        self.minutesToFull = minutesToFull
        self.insideTempC = insideTempC
        self.outsideTempC = outsideTempC
        self.doorsOpen = doorsOpen
        self.windowsOpen = windowsOpen
        self.isLocked = isLocked
        self.trunkOpen = trunkOpen
        self.odometerKm = odometerKm
        self.isOnline = isOnline
        self.isAsleep = isAsleep
        self.timestamp = timestamp
    }
}

@main
struct TesBarApp {
    static func main() {
        print("TesBar")
    }
}
