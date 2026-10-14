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

/// Polling state machine (ADR-0001, settled): fetch on menu open; 60 s while
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

    private static let chargingInterval: TimeInterval = 60
    private static let idleInterval: TimeInterval = 15 * 60
    private static let selectedIDKey = "selectedVehicleID"

    private let client: any TeslaClient
    private let clock: any PollClock
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?

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

    /// Menu just opened: fetch fresh data unconditionally (user story 7).
    public func menuOpened() async {
        await refresh()
    }

    /// Manual refresh; same rules as a menu open.
    public func refreshNow() async {
        await refresh()
    }

    /// Switch the displayed vehicle and remember it as the default (user stories 16/17).
    public func selectVehicle(_ id: String) async {
        guard id != selectedVehicleID else { return }
        selectedVehicleID = id
        defaults.set(id, forKey: Self.selectedIDKey)
        snapshot = nil
        lastUpdated = nil
        await load(id)
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

    private func load(_ id: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await client.vehicleData(id: id)
            lastUpdated = await clock.now()
            self.error = nil
        } catch {
            self.error = Self.describe(error)
        }
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
            guard let id = selectedVehicleID, snapshot?.state == .online else { continue }
            await load(id)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
