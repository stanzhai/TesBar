import AppKit
import SwiftUI

// MARK: - 纯状态机（无 UI、无 I/O；测试直接驱动）

/// 向导步骤：登录 → 配对 → 完成（ADR-0004：凭据/私钥已内置，向导只剩
/// OAuth 与配对；配对步内含自动拉车验证）。
public enum SetupStep: Int, CaseIterable, Sendable, Equatable {
    case login, pair, done

    var previous: SetupStep? { rawValue > 0 ? SetupStep(rawValue: rawValue - 1) : nil }
    var nextStep: SetupStep? { SetupStep(rawValue: rawValue + 1) }
}

/// 步进状态机：每步可前进/回退；首步不可回退、末步不可前进。
public struct SetupStepFlow: Equatable, Sendable {
    public private(set) var step: SetupStep

    public init(step: SetupStep = .login) { self.step = step }

    /// 登录态决定起点：已登录（Keychain 有 refresh token）从配对步开始
    /// （重看配对链接/重新配对场景），否则从登录步开始。
    public static func resuming(isLoggedIn: Bool) -> SetupStepFlow {
        SetupStepFlow(step: isLoggedIn ? .pair : .login)
    }

    public mutating func next() { if let n = step.nextStep { step = n } }
    public mutating func back() { if let p = step.previous { step = p } }
}

// MARK: - Presenter（@Observable，视图保持薄）

/// 首启向导编排（ADR-0004）：OAuth 登录（内置凭据，04 的 AuthService）、
/// 共享 VCP 密钥配对链接展示 + 自动拉车验证（05）。逻辑全在此处，
/// `SetupWizardView` 只做绑定。
@available(macOS 14, *)
@MainActor
@Observable
public final class SetupWizard {
    public static let completeKey = "setupComplete"

    public private(set) var flow: SetupStepFlow
    // 步骤输出
    public private(set) var publicKeyPEM: String?
    public private(set) var vehicles: [VehicleListEntry] = []
    public private(set) var isLoggedIn = false
    public private(set) var isWorking = false
    public private(set) var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let keys: VCPKeyManager
    @ObservationIgnored private let authFactory: () -> AuthService
    @ObservationIgnored private let clientFactory: (AuthService) -> any TeslaClient
    @ObservationIgnored private var auth: AuthService?

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(),
        keys: VCPKeyManager? = nil,
        authFactory: @escaping () -> AuthService = { AuthService() },
        clientFactory: @escaping (AuthService) -> any TeslaClient = { auth in
            let resolver = RegionResolver(defaults: .standard)
            return FleetTeslaClient(
                transport: RegionRedirectTransport(base: URLSessionTransport(), resolver: resolver),
                auth: auth,
                resolver: resolver
            )
        }
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keys = keys ?? VCPKeyManager()
        self.authFactory = authFactory
        self.clientFactory = clientFactory
        flow = SetupStepFlow()
        restore()
    }

    /// 首启标记；app 据此决定是否再弹向导（09/11 接线）。
    public var isComplete: Bool { defaults.bool(forKey: Self.completeKey) }

    /// 配对链接：内置托管域名 → `https://tesla.cn/_ak/<domain>`（注册 Virtual Key 入口；中国区）。
    nonisolated public static func pairingURL(domain: String = BuildConfig.pairingDomain) -> URL? {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "https://tesla.cn/_ak/\(encoded)")
    }

    public var pairingURL: URL? { Self.pairingURL() }

    /// 登录失败文案：reauthRequired/refreshTokenInvalid 给重登指引（user story 34），
    /// clientCredentialsRejected 指向构建注入的凭据（重登无用），其余原样。
    nonisolated public static func guidanceMessage(_ error: Error) -> String {
        switch error as? AuthError {
        case .reauthRequired: return "登录已失效，请重新登录"
        case .refreshTokenInvalid: return "登录凭据无效，请重新登录"
        case .clientCredentialsRejected(let detail):
            return "Tesla 服务端拒绝了 client_id 与 client_secret（\(detail)）。此凭据为构建内置，请联系分发者。"
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 步骤动作（视图按钮逐一调用）

    /// 登录步：ASWebAuthenticationSession 取 code → exchange 落 Keychain（04，UI 部分不单测）。
    public func login() async {
        isWorking = true
        defer { isWorking = false }
        let auth = authFactory()
        self.auth = auth
        do {
            try await auth.authorize()
            isLoggedIn = true
            error = nil
            advance()
        } catch {
            self.error = Self.guidanceMessage(error)
        }
    }

    /// 配对步：加载共享公钥（从内置私钥推导；ADR-0004）。进入步骤时调用。
    public func prepareKeyPair() {
        do { publicKeyPEM = try keys.publicKeyPEM() } catch {
            self.error = Self.guidanceMessage(error)
        }
    }

    /// 配对步：listVehicles 拉车辆列表（自动验证；找到车即可完成）。
    public func verify() async {
        isWorking = true
        defer { isWorking = false }
        let auth = self.auth ?? authFactory()
        self.auth = auth
        do {
            vehicles = try await clientFactory(auth).listVehicles()
            error = nil
        } catch {
            vehicles = []
            self.error = Self.guidanceMessage(error)
        }
    }

    /// 完成步：置 setupComplete 标记（即使用户跳过验证——标记含义是“向导已走完，不再打扰”）。
    public func complete() {
        guard flow.step == .pair else { return }
        defaults.set(true, forKey: Self.completeKey)
        flow.next()
    }

    // MARK: 步进

    public func advance() {
        flow.next()
        if flow.step == .done { defaults.set(true, forKey: Self.completeKey) }
    }

    /// 每步可跳过：不执行该步动作直接前进；到达 done 同样置完成标记。
    public func skip() { advance() }

    public func back() { flow.back() }

    // MARK: 启动恢复

    private func restore() {
        isLoggedIn = keychain.hasToken(AuthService.refreshAccount)
        flow = SetupStepFlow.resuming(isLoggedIn: isLoggedIn)
    }
}

// MARK: - 视图（编译即验收：无 GUI CI；逻辑均在 SetupWizard）

@available(macOS 14, *)
public struct SetupWizardView: View {
    /// App scene id：`Window(id:)` 与 `openWindow(id:)` 共用。
    public static let windowID = "setup-wizard"
    @Bindable var wizard: SetupWizard
    @Environment(\.dismiss) private var dismiss

    public init(wizard: SetupWizard) { self.wizard = wizard }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TesBar 设置 · 第 \(stepIndex)/2 步")
                .font(.headline)

            Group {
                switch wizard.flow.step {
                case .login: loginStep
                case .pair: pairStep
                case .done: doneStep
                }
            }

            if let error = wizard.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if wizard.isWorking { ProgressView().controlSize(.small) }

            HStack {
                if wizard.flow.step != .login {
                    Button("上一步") { wizard.back() }
                }
                Spacer()
                if wizard.flow.step != .done {
                    Button("跳过") { wizard.skip() }
                }
                primaryButton
            }
        }
        .padding(16)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
            }
        }
    }

    private var stepIndex: Int {
        min(wizard.flow.step.rawValue + 1, SetupStep.allCases.count - 1)
    }

    @ViewBuilder private var primaryButton: some View {
        switch wizard.flow.step {
        case .login:
            Group {
                if wizard.isLoggedIn {
                    Text("已登录 ✓")
                } else {
                    Button("登录 Tesla 账户") { Task { await wizard.login() } }
                }
            }
        case .pair:
            wizard.vehicles.isEmpty
                ? Button("验证连接") { Task { await wizard.verify() } }
                : Button("完成设置") { wizard.complete() }
        case .done:
            Button("完成") { dismiss() }
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通过 Tesla 账户 OAuth 登录一次，之后无需重复登录。凭据已内置，无需配置。")
            if wizard.isLoggedIn { Text("已有有效登录。").foregroundStyle(.secondary) }
        }
    }

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在车上注册 Virtual Key（每辆新车只需一次）。打开配对链接，按屏幕提示在车内确认:")
            if let url = wizard.pairingURL {
                Text(url.absoluteString).font(.caption).foregroundStyle(.blue)
                Button("打开配对链接") { NSWorkspace.shared.open(url) }
            }
            if wizard.publicKeyPEM != nil {
                Text("公钥已随构建托管于 \(BuildConfig.pairingDomain)。").font(.caption).foregroundStyle(.secondary)
            }
            if wizard.vehicles.isEmpty {
                Text("配对完成后点“验证连接”拉取车辆。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("找到 \(wizard.vehicles.count) 辆车：\(wizard.vehicles.map(\.name).joined(separator: "、"))")
            }
        }
        .task { wizard.prepareKeyPair() }
    }

    private var doneStep: some View {
        Text("设置完成 ✓ 菜单栏见。")
    }
}
