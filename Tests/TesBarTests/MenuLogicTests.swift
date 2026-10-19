import Foundation
import Testing

@testable import TesBar

/// Ticket 09 acceptance: extract the menu's interactive logic into testable
/// units — long-press confirm state machine, optional biometric gate on top of
/// it, relative-time label, °C/°F display — so CI without a GUI still covers it.
@MainActor
struct MenuLogicTests {

    // MARK: - ConfirmGate (长按 1s 确认, ADR-0003)

    @Test func pressUnderOneSecondCancelsWithoutFiring() {
        let gate = ConfirmGate()
        let start = Date()
        gate.pressBegan()
        gate.tick(at: start.addingTimeInterval(0.5))
        // pressBegan samples the clock again, so elapsed is 0.5 minus a few µs —
        // exact equality is inherently flaky; assert with tolerance.
        if case .pressing(let progress) = gate.state {
            #expect(abs(progress - 0.5) < 0.05)
        } else {
            #expect(gate.state == .pressing(progress: 0.5))
        }
        gate.pressEnded()
        #expect(gate.state == .idle)
        #expect(gate.firedCount == 0)
    }

    @Test func pressAtOrPastOneSecondFiresOnce() {
        let gate = ConfirmGate()
        let start = Date()
        gate.pressBegan()
        gate.tick(at: start.addingTimeInterval(1.0))
        #expect(gate.state == .fired)
        #expect(gate.firedCount == 1)
        gate.tick(at: start.addingTimeInterval(1.2)) // no double-fire
        #expect(gate.firedCount == 1)
    }

    @Test func gateResetsForNextPress() {
        let gate = ConfirmGate()
        gate.pressBegan()
        gate.tick(at: Date().addingTimeInterval(1.0))
        gate.pressEnded() // reset after fire
        #expect(gate.state == .idle)
        gate.pressBegan()
        gate.tick(at: Date().addingTimeInterval(1.0))
        #expect(gate.firedCount == 2)
    }

    // MARK: - DangerousCommandCoordinator (门禁 on → must pass LocalAuthentication)

    @Test func gateEnabledBlocksExecuteUntilAuthenticationSucceeds() async {
        let executor = RecordingCommandInvoker()
        let bio = StubBiometricGate()
        let coordinator = DangerousCommandCoordinator(
            invoker: executor, biometrics: bio, gateEnabled: { true }
        )

        bio.result = .failure(DummyGateError())
        await pressOneSecond(coordinator, command: .unlock)
        #expect(executor.commands == [])

        bio.result = .success(())
        await pressOneSecond(coordinator, command: .unlock)
        #expect(executor.commands == [.unlock])
    }

    @Test func gateEnabledAuthFailureBlocksExecutor() async {
        let executor = RecordingCommandInvoker()
        let bio = StubBiometricGate()
        bio.result = .failure(DummyGateError())
        let coordinator = DangerousCommandCoordinator(
            invoker: executor, biometrics: bio, gateEnabled: { true }
        )

        await pressOneSecond(coordinator, command: .unlock)
        #expect(executor.commands == [])
        #expect(coordinator.confirmGate.state == .idle)
    }

    @Test func gateDisabledSendsStraightThrough() async {
        let executor = RecordingCommandInvoker()
        let coordinator = DangerousCommandCoordinator(
            invoker: executor, biometrics: StubBiometricGate(), gateEnabled: { false }
        )

        await pressOneSecond(coordinator, command: .remoteStart)
        #expect(executor.commands == [.remoteStart])
    }

    @Test func nonDangerousCommandBypassesGateEntirely() async {
        let executor = RecordingCommandInvoker()
        let bio = StubBiometricGate()
        bio.result = .failure(DummyGateError()) // even a failing gate must not block hvac
        let coordinator = DangerousCommandCoordinator(
            invoker: executor, biometrics: bio, gateEnabled: { true }
        )

        await coordinator.beginPress(.hvacOff)
        #expect(executor.commands == [.hvacOff])
        #expect(coordinator.confirmGate.state == .idle)
    }

    @Test func releasingBeforeOneSecondDiscardsCommand() async {
        let executor = RecordingCommandInvoker()
        let coordinator = DangerousCommandCoordinator(
            invoker: executor, biometrics: StubBiometricGate(), gateEnabled: { false }
        )

        await coordinator.beginPress(.unlock)
        await coordinator.tick(Date().addingTimeInterval(0.4)) // still short
        coordinator.endPress()
        #expect(executor.commands == [])
        // Gate armed for next press after release.
        await pressOneSecond(coordinator, command: .unlock)
        #expect(executor.commands == [.unlock])
    }

    // MARK: - Relative time (故事 14)

    @Test func updatedAgoLabel() {
        #expect(StatusFormatting.updatedAgo(30) == "刚刚更新")
        #expect(StatusFormatting.updatedAgo(90) == "1 分钟前更新")
        #expect(StatusFormatting.updatedAgo(3 * 60) == "3 分钟前更新")
        #expect(StatusFormatting.updatedAgo(90 * 60) == "1 小时前更新")
        #expect(StatusFormatting.updatedAgo(3 * 3600) == "3 小时前更新")
        #expect(StatusFormatting.updatedAgo(3 * 86400) == "3 天前更新")
    }

    // MARK: - Temperature unit (故事 37)

    @Test func celsiusToFahrenheitDisplay() {
        #expect(StatusFormatting.temp(celsius: 20, fahrenheit: false) == "20°C")
        #expect(StatusFormatting.temp(celsius: 20, fahrenheit: true) == "68°F")
        #expect(StatusFormatting.temp(celsius: 0, fahrenheit: true) == "32°F")
        #expect(StatusFormatting.temp(celsius: -12.5, fahrenheit: true) == "10°F")
        #expect(StatusFormatting.temp(celsius: 21.7, fahrenheit: false) == "22°C")
        #expect(StatusFormatting.temp(celsius: nil, fahrenheit: true) == nil)
    }

    // MARK: - Doors text (故事 12)
    @Test func doorsText() {
        #expect(StatusFormatting.doors(VehicleSnapshot.Doors(locked: true, frontTrunkOpen: false, rearTrunkOpen: false)) == "已锁车")
        #expect(StatusFormatting.doors(VehicleSnapshot.Doors(locked: false, frontTrunkOpen: false, rearTrunkOpen: false)) == "未锁")
        #expect(StatusFormatting.doors(VehicleSnapshot.Doors(locked: nil, frontTrunkOpen: false, rearTrunkOpen: false)) == "锁状态未知")
        #expect(StatusFormatting.doors(VehicleSnapshot.Doors(locked: true, frontTrunkOpen: true, rearTrunkOpen: true)) == "已锁车 · 前备箱开 · 后备箱开")
    }

    /// 长按事件序列：begin → 1s tick（触发）→ 松手。
    private func pressOneSecond(_ coordinator: DangerousCommandCoordinator, command: VehicleCommand) async {
        await coordinator.beginPress(command)
        await coordinator.tick(Date().addingTimeInterval(1.1))
        coordinator.endPress()
    }
}

// MARK: - Test doubles

struct DummyGateError: Error {}

@MainActor
final class RecordingCommandInvoker: CommandInvoking {
    var commands: [VehicleCommand] = []
    func invoke(_ command: VehicleCommand) async { commands.append(command) }
}

final class StubBiometricGate: BiometricGate, @unchecked Sendable {
    var result: Result<Void, Error> = .success(())
    func authenticate(reason: String) async -> Result<Void, Error> { result }
}
