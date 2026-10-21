import Foundation
import Testing

@testable import TesBar

// MARK: - Test doubles

/// Manual clock: `advance` moves virtual time and wakes sleepers, so poll
/// timing is driven by the test, not wall time.
actor ManualClock: PollClock {
    private var nowMs: Int64 = 0
    private var nextID = 0
    private struct Sleeper {
        let id: Int
        let deadline: Int64
        let resume: CheckedContinuation<Void, any Error>
    }
    private var sleepers: [Sleeper] = []

    func now() -> Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1000) }

    func sleep(for seconds: TimeInterval) async throws {
        let deadline = nowMs + Int64((seconds * 1000).rounded())
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                sleepers.append(Sleeper(id: id, deadline: deadline, resume: cont))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).resume.resume(throwing: CancellationError())
    }

    /// Sleepers waiting on this clock; lets tests await poll-loop registration deterministically.
    func pendingSleepers() -> Int { sleepers.count }

    func advance(_ seconds: TimeInterval) {
        nowMs += Int64((seconds * 1000).rounded())
        let due = sleepers.filter { $0.deadline <= nowMs }
        sleepers.removeAll { $0.deadline <= nowMs }
        for sleeper in due { sleeper.resume.resume(returning: ()) }
    }
}

/// Scripted TeslaClient: every call is recorded; snapshots come off a queue.
/// `list` 可变：wakeNow 后测试把 state 翻回 online 模拟车醒。
private actor FakeTeslaClient: TeslaClient {
    private(set) var listCalls = 0
    private(set) var dataCalls: [String] = []
    private(set) var wakeCalls: [String] = []

    var list: [VehicleListEntry]
    var snapshots: [VehicleSnapshot]
    var failNextData: (any Error)?


    init(list: [VehicleListEntry], snapshots: [VehicleSnapshot]) {
        self.list = list
        self.snapshots = snapshots
    }

    func listVehicles() async throws -> [VehicleListEntry] {
        listCalls += 1
        return list
    }

    func vehicleData(id: String) async throws -> VehicleSnapshot {
        dataCalls.append(id)
        if let failure = failNextData {
            failNextData = nil
            throw failure
        }
        if snapshots.count > 1 { snapshots.removeFirst() }
        return snapshots[0]
    }

    func setFailNextData(_ error: any Error) { failNextData = error }

    func setSnapshots(_ s: [VehicleSnapshot]) { snapshots = s }

    func wake(id: String) async throws { wakeCalls.append(id) }

    func signAndSend(command: VehicleCommand, vehicleID: String) async throws {}

    func refreshAccessToken() async throws {}
}

// MARK: - Fixtures

private func snapshot(
    state: VehicleSnapshot.State, charging: Bool = false, locked: Bool = true, driving: Bool = false
) -> VehicleSnapshot {
    VehicleSnapshot(
        charge: .init(
            batteryPercent: 77, rangeKm: 238.6,
            state: charging ? "Charging" : "Stopped", minutesToFull: charging ? 45 : nil
        ),
        climate: .init(insideC: 21.5, outsideC: 8.0),
        doors: .init(locked: locked, frontTrunkOpen: false, rearTrunkOpen: false),
        odometerKm: 12_834.2, state: state, driving: driving,
        timestampMs: 1_760_000_000_000
    )
}

@available(macOS 14, *)
@MainActor
private func makeStore(
    list: [VehicleListEntry] = [VehicleListEntry(id: "car1", name: "My Tesla", state: "online")],
    snapshots: [VehicleSnapshot],
    defaults: UserDefaults
) async -> (VehicleStore, ManualClock, FakeTeslaClient) {
    let clock = ManualClock()
    let client = FakeTeslaClient(list: list, snapshots: snapshots)
    let store = VehicleStore(client: client, clock: clock, defaults: defaults)
    return (store, clock, client)
}

/// Isolated defaults per test; removed on teardown.
@MainActor
private func isolatedDefaults() -> UserDefaults {
    let suite = "VehicleStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// Barrier: poll loop runs on a background task; hop through yieldUntilPending
/// before advancing virtual time so registration always precedes advance().
private func yieldUntilPending(_ clock: ManualClock, count: Int = 1) async {
    while await clock.pendingSleepers() < count {
        await Task.yield()
    }
}

/// Bounded real-time wait until the fake records `target` data calls.
private func waitForDataCalls(_ client: FakeTeslaClient, _ target: Int) async {
    for _ in 0..<500 {
        if await client.dataCalls.count >= target { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Lets a wrongly-fired poll (if any) register before a negative assertion.
private func settle() async { try? await Task.sleep(nanoseconds: 50_000_000) }

// MARK: - Tests

@available(macOS 14, *) @MainActor @Test func menuOpenFetchesImmediately() async throws {
    let store = await makeStore(
        snapshots: [snapshot(state: .online)], defaults: isolatedDefaults()
    ).0

    #expect(store.snapshot == nil)
    await store.menuOpened()
    #expect(store.vehicles.count == 1)
    #expect(store.snapshot?.state == .online)
    #expect(store.lastUpdated != nil)
    #expect(store.error == nil)
}

@available(macOS 14, *) @MainActor @Test func chargingPollsEvery60Seconds() async throws {
    let (store, clock, client) = await makeStore(
        snapshots: [snapshot(state: .online, charging: true)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    store.startPolling()
    let callsAtOpen = await client.dataCalls.count

    await yieldUntilPending(clock)
    await clock.advance(60)
    await waitForDataCalls(client, callsAtOpen + 1)
    await yieldUntilPending(clock)
    await clock.advance(60)
    await waitForDataCalls(client, callsAtOpen + 2)
    store.stopPolling()
}

/// 行驶中 60s 一拉（位置自动跟上），停车后回 15 分钟档。
@available(macOS 14, *) @MainActor @Test func drivingPollsEvery60Seconds() async throws {
    let (store, clock, client) = await makeStore(
        snapshots: [snapshot(state: .online, driving: true)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    store.startPolling()
    let callsAtOpen = await client.dataCalls.count

    await yieldUntilPending(clock)
    await clock.advance(60)
    await waitForDataCalls(client, callsAtOpen + 1) // 60s 已拉，不等 900s

    // 停车：fake 单快照队列，下次拉取才返回 parked——第一轮 60s 拉到 driving（+1），
    // 再 60s 拉到 parked（+2），之后进 900s 档，剩余 240s 不再拉。
    await client.setSnapshots([snapshot(state: .online)])
    await yieldUntilPending(clock)
    await clock.advance(300)
    await waitForDataCalls(client, callsAtOpen + 2)
    await settle()
    #expect(await client.dataCalls.count == callsAtOpen + 2)
    store.stopPolling()
}

@available(macOS 14, *) @MainActor @Test func idleOnlinePollsEvery15MinutesOnly() async throws {
    let (store, clock, client) = await makeStore(
        snapshots: [snapshot(state: .online)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    store.startPolling()
    let callsAtOpen = await client.dataCalls.count

    await yieldUntilPending(clock)
    await clock.advance(300)
    // 300 s: no poll yet. The advance already woke any sleeper; only a wrong cadence would have fired.
    await settle()
    #expect(await client.dataCalls.count == callsAtOpen)

    await yieldUntilPending(clock) // 900 s total
    await clock.advance(600)
    await waitForDataCalls(client, callsAtOpen + 1)
    store.stopPolling()
}

@available(macOS 14, *) @MainActor @Test func sleepingVehicleIsNeverPolledOrWoken() async throws {
    let (store, clock, client) = await makeStore(
        list: [VehicleListEntry(id: "car1", name: "My Tesla", state: "asleep")],
        snapshots: [snapshot(state: .asleep)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    store.startPolling()
    // ADR-0004：睡眠车连 menuOpened 也不拉 vehicle_data。
    #expect(await client.dataCalls.isEmpty)
    #expect(store.snapshot == nil)
    #expect(store.vehicles.first?.state == "asleep")

    await yieldUntilPending(clock)
    await clock.advance(900)
    await yieldUntilPending(clock)
    await settle()
    #expect(await client.dataCalls.isEmpty) // no data poll while asleep
    #expect(await client.wakeCalls.isEmpty) // and never woken for data
    store.stopPolling()
}

@available(macOS 14, *) @MainActor @Test func offlineListStateSkipsVehicleData() async throws {
    let (store, _, client) = await makeStore(
        list: [VehicleListEntry(id: "car1", name: "My Tesla", state: "offline")],
        snapshots: [snapshot(state: .offline)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    #expect(await client.dataCalls.isEmpty)
    #expect(store.snapshot == nil)
    #expect(store.error == nil)
    #expect(store.isLoading == false)
}

/// 车刚睡着但 list state 滞后（online/""）→ vehicle_data 503 (vehicleNotAwake)。
/// 回写 state=asleep：旧快照 + zzz 角标接管，不弹英文系统报错。
@available(macOS 14, *) @MainActor @Test func staleOnlineStateSurfacesAsSleepingOnNotAwake() async throws {
    let (store, _, client) = await makeStore(
        snapshots: [snapshot(state: .online)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    await store.awaitPendingLoadsForTest()
    #expect(store.snapshot?.state == .online) // 有过一次成功取数

    // 车睡了：list 仍报 online（缓存滞后），vehicle_data 变 503。
    await client.setFailNextData(FleetError.vehicleNotAwake)
    await store.refreshAfterCommand() // force 拉数路径
    #expect(store.error == nil) // 不是红字英文报错
    #expect(store.snapshot?.state == .online) // 旧快照保留
    #expect(store.vehicles.first?.state == "asleep") // list state 已纠正

    await store.menuOpened() // 再次打开：isOnline 守卫生效，不再打 vehicle_data
    #expect(await client.dataCalls.count == 2) // 初次成功 + 503 那次；守卫生效后不再加
}


/// 发令后确认刷新：list 还是 asleep（executor 刚把车唤醒，list state 未更新），
/// refreshAfterCommand 必须绕过 isOnline 守卫拉到新快照。
@available(macOS 14, *) @MainActor @Test func refreshAfterCommandBypassesSleepGuard() async throws {
    let (store, _, client) = await makeStore(
        list: [VehicleListEntry(id: "car1", name: "My Tesla", state: "asleep")],
        snapshots: [snapshot(state: .online, charging: true)], defaults: isolatedDefaults()
    )
    await store.menuOpened() // asleep 守卫：不拉数据
    #expect(store.snapshot == nil)

    await store.refreshAfterCommand()
    #expect(await client.dataCalls == ["car1"])
    #expect(store.snapshot?.charge.state == "Charging")
}

@available(macOS 14, *) @MainActor @Test func refreshAfterCommandPollsUntilLockFlips() async throws {
    let (store, _, client) = await makeStore(
        snapshots: [snapshot(state: .online, locked: true)],  // single: every call returns it
        defaults: isolatedDefaults()
    )
    await store.menuOpened()
    await store.awaitPendingLoadsForTest()
    #expect(store.snapshot?.doors.locked == true)

    // Immediate refresh still stale → not converged yet.
    await store.refreshAfterCommand()
    #expect(store.snapshot?.doors.locked == true)

    // Backend catches up: next fetch flips the field.
    await client.setSnapshots([snapshot(state: .online, locked: false)])
    let done = await store.pollAfterCommand(expected: .unlock, baseline: store.snapshot)
    #expect(done)
    #expect(store.snapshot?.doors.locked == false)
    store.stopPolling()
}

@available(macOS 14, *) @MainActor @Test func wakeNowWakesThenFetches() async throws {
    let (store, _, client) = await makeStore(
        list: [VehicleListEntry(id: "car1", name: "My Tesla", state: "asleep")],
        snapshots: [snapshot(state: .online)], defaults: isolatedDefaults()
    )
    await store.menuOpened()
    #expect(await client.dataCalls.isEmpty)

    await store.wakeNow()
    #expect(await client.wakeCalls == ["car1"])
    #expect(await client.dataCalls == ["car1"]) // wake 后立即取数
    #expect(store.snapshot?.state == .online)
    #expect(store.error == nil)
}

@available(macOS 14, *) @MainActor @Test func switchingVehicleFetchesSelectionAndPersistsIt() async throws {
    let defaults = isolatedDefaults()
    let (store, _, client) = await makeStore(
        list: [
            VehicleListEntry(id: "car1", name: "Daily", state: "online"),
            VehicleListEntry(id: "car2", name: "Weekend", state: "online"),
        ],
        snapshots: [snapshot(state: .online)], defaults: defaults
    )
    await store.menuOpened()
    #expect(store.selectedVehicleID == "car1")

    await store.selectVehicle("car2")
    await store.awaitPendingLoadsForTest()
    #expect(await client.dataCalls.last == "car2")
    #expect(defaults.string(forKey: "selectedVehicleID") == "car2")

    // A fresh store (app relaunch) restores the remembered selection.
    let clock2 = ManualClock()
    let client2 = FakeTeslaClient(
        list: [
            VehicleListEntry(id: "car1", name: "Daily", state: "online"),
            VehicleListEntry(id: "car2", name: "Weekend", state: "online"),
        ],
        snapshots: [snapshot(state: .online)]
    )
    let relaunched = VehicleStore(client: client2, clock: clock2, defaults: defaults)
    await relaunched.menuOpened()
    #expect(relaunched.selectedVehicleID == "car2")
    #expect(await client2.dataCalls == ["car2"])
}

@available(macOS 14, *) @MainActor @Test func listFailureSurfacesAsError() async throws {
    let clock = ManualClock()
    let client = FailingListClient()
    let store = VehicleStore(client: client, clock: clock, defaults: isolatedDefaults())

    await store.menuOpened()
    #expect(store.error != nil)
    #expect(store.snapshot == nil)
}

@available(macOS 14, *) @MainActor @Test func signOutClearsVehiclesAndSelection() async throws {
    let defaults = isolatedDefaults()
    let (store, _, _) = await makeStore(
        snapshots: [snapshot(state: .online)], defaults: defaults
    )
    await store.menuOpened()
    #expect(store.vehicles.count == 1)

    store.clearForSignOut()
    #expect(store.vehicles.isEmpty)
    #expect(store.snapshot == nil)
    #expect(store.selectedVehicleID == nil)
    #expect(store.error == nil)
    #expect(defaults.string(forKey: "selectedVehicleID") == nil)
}

private struct FailingListClient: TeslaClient {
    struct Boom: LocalizedError { var errorDescription: String? { "network down" } }
    func listVehicles() async throws -> [VehicleListEntry] { throw Boom() }
    func vehicleData(id: String) async throws -> VehicleSnapshot { snapshot(state: .online) }
    func wake(id: String) async throws {}
    func signAndSend(command: VehicleCommand, vehicleID: String) async throws {}
    func refreshAccessToken() async throws {}
}
