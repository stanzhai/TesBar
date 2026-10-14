import Foundation

@testable import TesBar

/// 脚本化假 TeslaClient：每个方法按预设队列返回结果，队列耗尽后重复最后一个（空队列用内置默认）。
/// 记录调用名顺序与发出的指令，供测试断言"先 Wake 后发令"等编排行为。
actor FakeTeslaClient: TeslaClient {
    private(set) var calls: [String] = []
    private(set) var sentCommands: [VehicleCommand] = []

    private var dataScript: [Result<VehicleSnapshot, Error>]
    private var wakeScript: [Result<Void, Error>]
    private var sendScript: [Result<Void, Error>]

    init(
        data: [Result<VehicleSnapshot, Error>] = [],
        wake: [Result<Void, Error>] = [],
        send: [Result<Void, Error>] = []
    ) {
        dataScript = data
        wakeScript = wake
        sendScript = send
    }

    func listVehicles() async throws -> [VehicleListEntry] {
        calls.append("listVehicles")
        return []
    }

    func vehicleData(id: String) async throws -> VehicleSnapshot {
        calls.append("vehicleData")
        return try next(&dataScript, fallback: .success(Self.snapshot(state: .online))).get()
    }

    func wake(id: String) async throws {
        calls.append("wake")
        try next(&wakeScript, fallback: .success(())).get()
    }

    func signAndSend(command: VehicleCommand) async throws {
        calls.append("signAndSend")
        sentCommands.append(command)
        try next(&sendScript, fallback: .success(())).get()
    }

    func refreshAccessToken() async throws {
        calls.append("refreshAccessToken")
    }

    /// 队列多于一个时消费队头；只剩最后一个时反复返回它；空队列返回 fallback。
    private func next<T>(_ script: inout [Result<T, Error>], fallback: Result<T, Error>) -> Result<T, Error> {
        if script.count > 1 { return script.removeFirst() }
        return script.last ?? fallback
    }

    /// 最小可用快照，测试按需换 state。
    static func snapshot(state: VehicleSnapshot.State) -> VehicleSnapshot {
        VehicleSnapshot(
            charge: .init(batteryPercent: 50, rangeKm: 200, state: "Stopped", minutesToFull: nil),
            climate: .init(insideC: nil, outsideC: nil),
            doors: .init(locked: true, anyOpen: false, frontTrunkOpen: false, rearTrunkOpen: false),
            odometerKm: 1000,
            state: state,
            timestampMs: 0
        )
    }
}
