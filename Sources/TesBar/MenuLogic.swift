import Foundation
import LocalAuthentication

// MARK: - 长按确认门 (ADR-0003)

/// 危险指令长按 1 秒确认的状态机：idle → pressing(progress) → fired / idle。
/// 时间由调用方喂入（按钮的 tick），本体纯逻辑、可测。
@MainActor
public final class ConfirmGate: ObservableObject {
    public enum State: Equatable {
        case idle
        case pressing(progress: Double)
        case fired
    }

    @Published public private(set) var state: State = .idle
    public private(set) var firedCount = 0

    private var pressedAt: Date?

    public init() {}

    public func pressBegan() {
        pressedAt = Date()
        state = .pressing(progress: 0)
    }

    /// 调用方按显示节奏喂当前时刻；≥1s 时触发一次（重复 tick 不再触发）。
    public func tick(at date: Date) {
        guard let start = pressedAt, state != .fired else { return }
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 1 else {
            state = .pressing(progress: max(0, elapsed))
            return
        }
        state = .fired
        firedCount += 1
    }

    public func pressEnded() {
        pressedAt = nil
        state = .idle
    }
}

// MARK: - 门禁 (LocalAuthentication, 默认关)

/// 生产实现包 LAContext.deviceOwnerAuthentication；测试注入假 gate。
public protocol BiometricGate: Sendable {
    func authenticate(reason: String) async -> Result<Void, Error>
}

public struct LocalAuthGate: BiometricGate {
    public init() {}

    public func authenticate(reason: String) async -> Result<Void, Error> {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .failure(error ?? LAError(.notInteractive))
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

/// 指令出口微协议：CommandExecutor 或测试替身。MainActor 隔离与 coordinator 一致。
@MainActor
public protocol CommandInvoking: AnyObject {
    func invoke(_ command: VehicleCommand) async
}

/// 危险指令编排（ADR-0003）：长按达 1s（ConfirmGate fired）→ 门禁开启时先过
/// LocalAuthentication → 成功才落到 invoker。非危险指令不经此类型（UI 直发）。
/// 事件驱动：``beginPress(_:)/endPress()`` 配对，``tick(_:)`` 由按钮节奏喂入。
@MainActor
public final class DangerousCommandCoordinator: ObservableObject {
    public let confirmGate = ConfirmGate()

    private let invoker: any CommandInvoking
    private let biometrics: any BiometricGate
    private let gateEnabled: () -> Bool
    /// 非空 ⇔ 有一条指令在长按等待中。
    private var pendingCommand: VehicleCommand?

    public init(
        invoker: any CommandInvoking,
        biometrics: any BiometricGate,
        gateEnabled: @escaping () -> Bool
    ) {
        self.invoker = invoker
        self.biometrics = biometrics
        self.gateEnabled = gateEnabled
    }

    /// 按下危险指令按钮：挂起指令并启动 1s 计时。非危险指令立即直发（兜底）。
    public func beginPress(_ command: VehicleCommand) async {
        guard command.isDangerous else {
            await invoker.invoke(command)
            return
        }
        pendingCommand = command
        confirmGate.pressBegan()
    }

    /// 松手：未满 1s 时丢弃指令（已触发过的发令照常进行）。
    public func endPress() {
        pendingCommand = nil
        confirmGate.pressEnded()
    }

    /// 按钮 tick：推进 ConfirmGate；fired 即按门禁状态发令（只发一次）。
    public func tick(_ date: Date) async {
        confirmGate.tick(at: date)
        guard confirmGate.state == .fired else { return }
        confirmGate.pressEnded()
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        if gateEnabled() {
            guard case .success = await biometrics.authenticate(reason: "确认执行危险指令") else { return }
        }
        await invoker.invoke(command)
    }
}

// MARK: - 状态展示格式化

/// 菜单文案纯函数（故事 14 相对时间、37 温度单位、12 锁/门文案）。
public enum StatusFormatting {
    /// “多久前更新”。<60s 刚刚；分钟/小时/天向下取整。
    public static func updatedAgo(_ seconds: TimeInterval, now _: Date = Date()) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "刚刚更新"
        case ..<3600: return "\(s / 60) 分钟前更新"
        case ..<86400: return "\(s / 3600) 小时前更新"
        default: return "\(s / 86400) 天前更新"
        }
    }

    /// °C/°F 显示：华氏换算并四舍五入；nil 保持 nil（睡眠/离线无温度）。
    public static func temp(celsius: Double?, fahrenheit: Bool) -> String? {
        guard let celsius else { return nil }
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))\(fahrenheit ? "°F" : "°C")"
    }

    /// 车门/锁/后备箱文案（故事 12）。
    public static func doors(_ doors: VehicleSnapshot.Doors) -> String {
        var parts: [String] = [doors.locked ? "已锁车" : "未锁"]
        if doors.frontTrunkOpen { parts.append("前备箱开") }
        if doors.rearTrunkOpen { parts.append("后备箱开") }
        if doors.anyOpen { parts.append("有车门开") }
        return parts.joined(separator: " · ")
    }
}
