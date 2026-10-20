import Foundation
import Testing

@testable import TesBar

/// Ticket 07 acceptance: wake-before-send, awake direct send, pairing guidance,
/// success silent, retry, wake timeout — via scripted ScriptedTeslaClient + spy notifier + fake sleeper.
@MainActor
struct CommandExecutorTests {
    private let online = ScriptedTeslaClient.snapshot(state: .online)
    private let asleep = ScriptedTeslaClient.snapshot(state: .asleep)

    @Test func asleepVehicleWakesThenSends() async {
        let client = ScriptedTeslaClient(data: [.success(asleep), .success(online)])
        let notifier = SpyNotifier()
        let executor = CommandExecutor(client: client, notifier: notifier, sleep: { _ in })

        await executor.execute(.horn, vehicleID: "V1")

        let calls = await client.calls
        #expect(calls == ["vehicleData", "wake", "vehicleData", "signAndSend"])
        #expect(executor.status == .succeeded)
        #expect(await notifier.sent.isEmpty)
    }

    @Test func awakeVehicleSendsDirectlyWithoutWake() async {
        let client = ScriptedTeslaClient(data: [.success(online)])
        let notifier = SpyNotifier()
        let executor = CommandExecutor(client: client, notifier: notifier, sleep: { _ in })

        await executor.execute(.hvacOff, vehicleID: "V1")

        let calls = await client.calls
        #expect(calls == ["vehicleData", "signAndSend"])
        #expect(calls.contains("wake") == false)
        #expect(executor.status == .succeeded)
        #expect(await notifier.sent.isEmpty)
    }

    @Test func unpairedVirtualKeyShowsGuidanceAndNotifies() async {
        let client = ScriptedTeslaClient(data: [.success(online)], send: [.failure(VirtualKeyNotPairedError())])
        let notifier = SpyNotifier()
        let executor = CommandExecutor(client: client, notifier: notifier)

        await executor.execute(.hvacOn, vehicleID: "V1")

        guard case .failed(let reason, let retryable) = executor.status else {
            Issue.record("expected failed status, got \(executor.status)")
            return
        }
        #expect(reason.contains("配对"))
        #expect(reason.contains("Virtual Key"))
        #expect(retryable == false)

        let sent = await notifier.sent
        #expect(sent.count == 1)
        #expect(sent.first?.body == reason)
    }

    @Test func retryResendsLastCommand() async {
        let client = ScriptedTeslaClient(data: [.success(online)])
        let notifier = SpyNotifier()
        let executor = CommandExecutor(client: client, notifier: notifier)

        await executor.execute(.hvacOn, vehicleID: "V1")
        await executor.retry()

        let commands = await client.sentCommands
        #expect(commands == [.hvacOn, .hvacOn])
        #expect(executor.status == .succeeded)
    }

    @Test func wakePollingIsBoundedAndTimesOut() async {
        let client = ScriptedTeslaClient(data: [.success(asleep)]) // never comes online
        let notifier = SpyNotifier()
        let sleeper = SleepSpy()
        let executor = CommandExecutor(
            client: client, notifier: notifier,
            wakeAttempts: 3, wakeInterval: 2,
            sleep: { seconds in await sleeper.sleep(seconds) }
        )

        await executor.execute(.horn, vehicleID: "V1")

        guard case .failed(let reason, let retryable) = executor.status else {
            Issue.record("expected failed status, got \(executor.status)")
            return
        }
        #expect(reason.contains("超时"))
        #expect(retryable)

        let calls = await client.calls
        // 1 initial fetch + 3 bounded wake polls, and the command never goes out.
        #expect(calls.filter { $0 == "vehicleData" }.count == 4)
        #expect(calls.contains("signAndSend") == false)
        #expect(await sleeper.durations == [2, 2, 2])
        #expect(await notifier.sent.count == 1)
    }

    @Test func unreachableDataFallsBackToWake() async {
        let client = ScriptedTeslaClient(data: [.failure(URLError(.notConnectedToInternet)), .success(online)])
        let notifier = SpyNotifier()
        let executor = CommandExecutor(client: client, notifier: notifier, sleep: { _ in })

        await executor.execute(.flashLights, vehicleID: "V1")

        let calls = await client.calls
        #expect(calls == ["vehicleData", "wake", "vehicleData", "signAndSend"])
        #expect(executor.status == .succeeded)
    }
}

// MARK: - Spies

actor SpyNotifier: Notifier {
    private(set) var sent: [(title: String, body: String)] = []

    func send(title: String, body: String) async {
        sent.append((title, body))
    }
}

actor SleepSpy {
    private(set) var durations: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        durations.append(seconds)
    }
}
