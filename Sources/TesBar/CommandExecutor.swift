import Foundation

/// 微协议：通知发送。生产实现为 UserNotificationsNotifier（失败才被调用，成功静默在 executor 层保证）。
public protocol Notifier: Sendable {
    func send(title: String, body: String) async
}

/// CommandExecutor 的人类可读状态行：发送中 → 成功 / 失败+原因+是否可重试（spec 故事 28）。
public enum CommandStatus: Sendable, Equatable {
    case idle
    case sending
    case succeeded
    case failed(reason: String, retryable: Bool)

    public static func == (lhs: CommandStatus, rhs: CommandStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.sending, .sending), (.succeeded, .succeeded):
            true
        case let (.failed(la, lr), .failed(ra, rr)):
            la == ra && lr == rr
        default:
            false
        }
    }
}

/// 编排：睡眠/离线（或数据拉不到）→ Wake → 短轮询至 online（有上限）→ 签名发令（ADR-0001、故事 31）。
/// 状态行由 UI（09）观察；失败才发通知，成功静默（故事 29/30）。
@MainActor
public final class CommandExecutor: ObservableObject {
    @Published public private(set) var status: CommandStatus = .idle

    private let client: any TeslaClient
    private let notifier: any Notifier
    private let wakeAttempts: Int
    private let wakeInterval: TimeInterval
    private let sleep: (TimeInterval) async -> Void

    private var lastCommand: VehicleCommand?
    private var lastVehicleID: String?

    /// 默认 10 次 × 2 秒的 wake 等待（ticket：bounded attempts, e.g. 10×2s）。
    public init(
        client: any TeslaClient,
        notifier: any Notifier,
        wakeAttempts: Int = 10,
        wakeInterval: TimeInterval = 2,
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.client = client
        self.notifier = notifier
        self.wakeAttempts = max(wakeAttempts, 1)
        self.wakeInterval = wakeInterval
        self.sleep = sleep
    }

    public func execute(_ command: VehicleCommand, vehicleID: String) async {
        lastCommand = command
        lastVehicleID = vehicleID
        await run(command: command, vehicleID: vehicleID)
    }

    /// 重发上一条指令（状态行的重试入口）；没有可重试的指令时保持原状态。
    public func retry() async {
        guard let command = lastCommand, let vehicleID = lastVehicleID else { return }
        await run(command: command, vehicleID: vehicleID)
    }

    private func run(command: VehicleCommand, vehicleID: String) async {
        status = .sending
        do {
            try await ensureAwake(vehicleID: vehicleID)
            try await client.signAndSend(command: command)
            status = .succeeded
        } catch {
            let reason = Self.describe(error)
            let retryable = !(error is VirtualKeyNotPairedError)
            status = .failed(reason: reason, retryable: retryable)
            await notifier.send(title: "指令失败", body: reason)
        }
    }

    /// 拉当前状态：非 online → wake 后轮询 vehicleData 至 online（带上限，超时抛错）。
    private func ensureAwake(vehicleID: String) async throws {
        if await currentState(vehicleID: vehicleID) == .online { return }

        try await client.wake(id: vehicleID)
        for _ in 0..<wakeAttempts {
            await sleep(wakeInterval)
            if await currentState(vehicleID: vehicleID) == .online { return }
        }
        throw WakeTimeoutError(attempts: wakeAttempts)
    }

    /// 拉不到数据按"可能睡眠/离线"处理（ticket：或拉不到 → wake），不在此步失败。
    private func currentState(vehicleID: String) async -> VehicleSnapshot.State? {
        try? await client.vehicleData(id: vehicleID).state
    }

    /// 失败 → 人类可读原因（故事 28/32）。401 已由 04/05 在 client 层处理续期，此处兜底。
    private static func describe(_ error: Error) -> String {
        if error is VirtualKeyNotPairedError {
            return "虚拟钥匙未配对：车辆拒绝签名指令。请先在设置中完成 Virtual Key 配对，再重发。"
        }
        if let timeout = error as? WakeTimeoutError {
            return "车辆唤醒超时：等待上线超过 \(timeout.attempts) 次轮询仍未 online，请稍后重试。"
        }
        if let urlError = error as? URLError {
            return "网络错误：\(urlError.localizedDescription)"
        }
        return "发送失败：\(error.localizedDescription)"
    }
}

/// wake 后 bounded 轮询仍不 online（避免无限唤醒等待；ADR-0001 红线是避免高频 Wake）。
struct WakeTimeoutError: Error {
    let attempts: Int
}
