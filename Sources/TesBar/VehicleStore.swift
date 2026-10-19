import Foundation
import Observation

/// Injectable clock that drives VehicleStore's poll cadence (ADR-0001).
/// Exists only so tests can drive time manually; no swift-clocks dependency.
public protocol PollClock: Sendable {
    func now() async -> Date
    func sleep(for seconds: TimeInterval) async throws
}

/// Wall-clock implementation for production.
public struct SystemPollClock: PollClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}


/// charging; 15 min otherwise and only while the vehicle is online; never wake
/// a sleeping car just to refresh data. Offline is a state, not an error.
@available(macOS 14, *)
@Observable
public final class VehicleStore: @unchecked Sendable {
    public private(set) var vehicles: [VehicleListEntry] = []
    public private(set) var selectedVehicleID: String?
    public private(set) var snapshot: VehicleSnapshot?
    public private(set) var isLoading = false
    /// When the displayed data was fetched; drives the "updated X ago" label (user story 14).
    public private(set) var lastUpdated: Date?
    /// Last fetch failure. An unreachable car surfaces as `snapshot.state == .offline`, not here (user story 15).
    public private(set) var error: String?
    /// 显式唤醒进行中（“唤醒”按钮转圈）。
    public private(set) var isWaking = false

    private static let chargingInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 15 * 60
    private static let selectedIDKey = "selectedVehicleID"

    private let client: any TeslaClient
    private let clock: any PollClock
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    public init(
        client: any TeslaClient,
        clock: any PollClock = SystemPollClock(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.clock = clock
        self.defaults = defaults
        selectedVehicleID = defaults.string(forKey: Self.selectedIDKey)
    }

    /// 退出登录（ADR-0004）：清列表/快照/错误。轮询不停（空转无害），
    /// 重登后 menuOpened/轮询自动恢复取数。
    public func clearForSignOut() {
        vehicles = []
        snapshot = nil
        selectedVehicleID = nil
        defaults.removeObject(forKey: Self.selectedIDKey)
        lastUpdated = nil
        error = nil
    }

    /// Menu just opened: fetch list; only an `online` car gets vehicle_data (ADR-0004).
    public func menuOpened() async {
        await refresh()
    }

    /// Manual refresh; same rules as a menu open.
    public func refreshNow() async {
        await refresh()
    }

    /// 显式唤醒（ADR-0004）：用户点了“唤醒”才唤醒。发指令仍由
    /// CommandExecutor.ensureAwake 自动唤醒（ADR-0001 不变）。
    public func wakeNow() async {
        guard let id = selectedVehicleID else { return }
        isWaking = true
        defer { isWaking = false }
        do {
            try await client.wake(id: id)
            await load(id, force: true)
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Switch the displayed vehicle and remember it as the default (user stories 16/17).
    public func selectVehicle(_ id: String) async {
        guard id != selectedVehicleID else { return }
        selectedVehicleID = id
        defaults.set(id, forKey: Self.selectedIDKey)
        snapshot = nil
        lastUpdated = nil
        await refresh()
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { await pollLoop() }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            vehicles = try await client.listVehicles()
            if let id = selectedVehicleID, vehicles.contains(where: { $0.id == id }) {
                await load(id)
            } else if let first = vehicles.first {
                // First run: default to the first vehicle (user story 5).
                selectedVehicleID = first.id
                defaults.set(first.id, forKey: Self.selectedIDKey)
                await load(first.id)
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// ADR-0004：list state 非 `online` 不拉 vehicle_data（睡眠车取数会 408 并
    /// 打断省电）。旧快照保留（方案 1）：UI 继续显示旧数据 + “数据为 X 前”角标，
    /// 只有无任何数据时才显示降级卡。
    private func load(_ id: String, force: Bool = false) {
        guard force || isOnline(id) else { return } // 旧快照保留，不清
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            do {
                let fresh = try await client.vehicleData(id: id)
                guard !Task.isCancelled else { return }
                snapshot = fresh
                lastUpdated = await clock.now()
                self.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = Self.describe(error)
            }
        }
    }

    /// 刷新按钮（新行为）：先拉 list，车不 online 就 wake 并轮询等 online
    ///（最多 ~40s），然后拉数据。全程 isWaking=true 防重复点击。
    public func wakeAndRefresh() async {
        guard !isWaking, let id = selectedVehicleID else { return }
        isWaking = true
        defer { isWaking = false }
        do {
            vehicles = try await client.listVehicles()
            guard let entry = vehicles.first(where: { $0.id == id }) else { return }
            if !entry.state.isEmpty, entry.state != "online" {
                try await client.wake(id: id)
                // wake 后车要几秒到几十秒才 online；每 2s 查一次，最多 20 次（40s）。
                for _ in 0..<20 {
                    try await clock.sleep(for: 2)
                    vehicles = try await client.listVehicles()
                    if vehicles.first(where: { $0.id == id })?.state == "online" { break }
                }
            }
            await refresh()
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// 测试钩子：等待内部 load 任务落定（load 现在异步启动）。
    public func awaitPendingLoadsForTest() async {
        while let t = loadTask, !t.isCancelled {
            _ = await t.value
            loadTask = nil
        }
    }

    /// list state == online（旧数据/测试数据无 state 时保守视为在线，保持旧行为）。
    private func isOnline(_ id: String) -> Bool {
        guard let entry = vehicles.first(where: { $0.id == id }) else { return false }
        return entry.state.isEmpty || entry.state == "online"
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let charging = snapshot?.charge.state == "Charging"
            do {
                try await clock.sleep(for: charging ? Self.chargingInterval : Self.idleInterval)
            } catch {
                return // stopPolling()
            }
            // Only poll an online car; never wake a sleeping one for data (ADR-0001).
            // 退出登录后 selectedVehicleID == nil → 空转一轮；重登自动恢复取数。
            guard let id = selectedVehicleID, isOnline(id) else { continue }
            await load(id)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
