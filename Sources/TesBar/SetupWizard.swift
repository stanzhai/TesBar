import AppKit
import SwiftUI

// MARK: - 纯状态机（无 UI、无 I/O；测试直接驱动）

/// 向导步骤：凭据 → 登录 → 密钥配对 → 验证 → 完成（spec user stories 1–5）。
public enum SetupStep: Int, CaseIterable, Sendable, Equatable {
    case credentials, login, keyPair, verify, done

    var previous: SetupStep? { rawValue > 0 ? SetupStep(rawValue: rawValue - 1) : nil }
    var nextStep: SetupStep? { SetupStep(rawValue: rawValue + 1) }
}

/// 步进状态机：每步可前进（=跳过，跳过即不执行该步动作）/回退；首步不可回退、末步不可前进。
public struct SetupStepFlow: Equatable, Sendable {
    public private(set) var step: SetupStep

    public init(step: SetupStep = .credentials) { self.step = step }

    /// 登录态决定起点：已登录（Keychain 有 refresh token）从密钥步开始；
    /// 凭据已存但未登录从登录步开始（续认证场景）；
    /// 全新从凭据步开始。也覆盖“未配对虚拟钥匙重看公钥”入口（09 从设置重开向导）。
    public static func resuming(hasCredentials: Bool, isLoggedIn: Bool) -> SetupStepFlow {
        SetupStepFlow(step: isLoggedIn ? .keyPair : hasCredentials ? .login : .credentials)
    }

    public mutating func next() { if let n = step.nextStep { step = n } }
    public mutating func back() { if let p = step.previous { step = p } }
}

// MARK: - Presenter（@Observable，视图保持薄）

/// 首启向导编排：凭据持久化（clientID→UserDefaults，secret→Keychain，user story 2/35）、
/// OAuth 登录（04 的 AuthService）、VCP 公钥展示与配对链接（03）、listVehicles 验证（05）、
/// 完成标记。逻辑全在此处，`SetupWizardView` 只做绑定。
@available(macOS 14, *)
@MainActor
@Observable
public final class SetupWizard {
    public static let clientIDKey = "tesbarClientID"
    public static let domainKey = "tesbarPairingDomain"
    public static let completeKey = "setupComplete"
    /// client secret 经 ``KeychainStore/saveToken(_:for:)`` 存 Keychain（同 04 的 token 约定）。
    public static let clientSecretAccount = "tesbar-client-secret"

    public private(set) var flow: SetupStepFlow
    // 步骤输入
    public var clientID = ""
    public var clientSecret = ""
    public var domain = ""
    // 步骤输出
    public private(set) var publicKeyPEM: String?
    public private(set) var vehicles: [VehicleListEntry] = []
    public private(set) var isLoggedIn = false
    public private(set) var isWorking = false
    public private(set) var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let keys: VCPKeyManager
    @ObservationIgnored private let authFactory: (String, String) -> AuthService
    @ObservationIgnored private let clientFactory: (AuthService) -> any TeslaClient
    @ObservationIgnored private var auth: AuthService?

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(),
        keys: VCPKeyManager? = nil,
        authFactory: @escaping (String, String) -> AuthService = { AuthService(clientID: $0, clientSecret: $1) },
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
        self.keys = keys ?? VCPKeyManager(store: keychain)
        self.authFactory = authFactory
        self.clientFactory = clientFactory
        flow = SetupStepFlow()
        restore()
    }

    /// 首启标记；app 据此决定是否再弹向导（09/11 接线）。
    public var isComplete: Bool { defaults.bool(forKey: Self.completeKey) }

    /// 配对链接：公钥托管域名 → `https://tesla.com/_ak/<domain>`（注册 Virtual Key 入口）。
    nonisolated public static func pairingURL(domain: String) -> URL? {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "https://tesla.com/_ak/\(encoded)")
    }

    public var pairingURL: URL? { Self.pairingURL(domain: domain) }

    /// 登录失败文案：reauthRequired/refreshTokenInvalid 给重登指引（user story 34），其余原样。
    nonisolated public static func guidanceMessage(_ error: Error) -> String {
        switch error as? AuthError {
        case .reauthRequired: return "登录已失效，请返回上一步重新登录"
        case .refreshTokenInvalid: return "登录凭据无效，请重新登录"
        default: return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 步骤动作（视图按钮逐一调用）

    /// 凭据步：校验非空并持久化（clientID 非机密→UserDefaults；secret→Keychain）。
    public func saveCredentials() {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty, !clientSecret.isEmpty else {
            error = "请填写 client id 与 client secret"
            return
        }
        defaults.set(clientID, forKey: Self.clientIDKey)
        do { try keychain.saveToken(clientSecret, for: Self.clientSecretAccount) } catch {
            self.error = Self.guidanceMessage(error)
            return
        }
        error = nil
        advance()
    }

    /// 登录步：ASWebAuthenticationSession 取 code → exchange 落 Keychain（04，UI 部分不单测）。
    public func login() async {
        isWorking = true
        defer { isWorking = false }
        let auth = authFactory(clientID, clientSecret)
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

    /// 密钥步：幂等确保 VCP 密钥对存在（03），展示公钥 PEM。
    public func prepareKeyPair() {
        do { publicKeyPEM = try keys.ensureKeyPair() } catch {
            self.error = Self.guidanceMessage(error)
        }
    }

    /// 密钥步：记住配对域名（ UserDefaults，下次重开向导回填）。
    public func saveDomain() {
        defaults.set(domain.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.domainKey)
    }

    /// 验证步：listVehicles 拉车辆数/名称（spec user story 5 的列表展示）。
    public func verify() async {
        isWorking = true
        defer { isWorking = false }
        let auth = self.auth ?? authFactory(clientID, clientSecret)
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
        guard flow.step == .verify else { return }
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
        clientID = defaults.string(forKey: Self.clientIDKey) ?? ""
        clientSecret = (try? keychain.readToken(Self.clientSecretAccount)) ?? ""
        domain = defaults.string(forKey: Self.domainKey) ?? ""
        isLoggedIn = keychain.hasToken(AuthService.refreshAccount)
        flow = SetupStepFlow.resuming(hasCredentials: !clientID.isEmpty && !clientSecret.isEmpty, isLoggedIn: isLoggedIn)
    }
}

// MARK: - 视图（编译即验收：无 GUI CI；逻辑均在 SetupWizard）

@available(macOS 14, *)
public struct SetupWizardView: View {
    @Bindable var wizard: SetupWizard
    @Environment(\.dismiss) private var dismiss

    public init(wizard: SetupWizard) { self.wizard = wizard }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TesBar 设置 · 第 \(stepIndex)/4 步")
                .font(.headline)

            Group {
                switch wizard.flow.step {
                case .credentials: credentialsStep
                case .login: loginStep
                case .keyPair: keyPairStep
                case .verify: verifyStep
                case .done: doneStep
                }
            }

            if let error = wizard.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if wizard.isWorking { ProgressView().controlSize(.small) }

            HStack {
                if wizard.flow.step != .credentials {
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
        case .credentials:
            Button("保存并继续") { wizard.saveCredentials() }
        case .login:
            Group {
                if wizard.isLoggedIn {
                    Text("已登录 ✓")
                } else {
                    Button("登录 Tesla 账户") { Task { await wizard.login() } }
                }
            }
        case .keyPair:
            Button("继续") {
                wizard.saveDomain()
                wizard.advance()
            }
        case .verify:
            wizard.vehicles.isEmpty
                ? Button("验证连接") { Task { await wizard.verify() } }
                : Button("完成设置") { wizard.complete() }
        case .done:
            Button("完成") { dismiss() }
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("填入你的开发者凭据（Fleet API client id/secret）:")
            TextField("client id", text: $wizard.clientID)
            SecureField("client secret", text: $wizard.clientSecret)
        }
    }

    private var loginStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("通过 Tesla 账户 OAuth 登录一次，之后无需重复登录。")
            if wizard.isLoggedIn { Text("已有有效登录。").foregroundStyle(.secondary) }
        }
    }

    private var keyPairStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VCP 公钥（私钥已存 Keychain）。把公钥托管到你的域名，再打开配对链接在车上注册 Virtual Key:")
            ScrollView {
                Text(wizard.publicKeyPEM ?? "正在生成…")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .border(Color.secondary.opacity(0.3))
            Button("复制公钥") {
                if let pem = wizard.publicKeyPEM {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pem, forType: .string)
                }
            }
            TextField("公钥托管域名（如 example.com）", text: $wizard.domain)
            if let url = wizard.pairingURL {
                Text(url.absoluteString).font(.caption).foregroundStyle(.blue)
                Button("打开配对链接") { NSWorkspace.shared.open(url) }
            }
        }
        .task { wizard.prepareKeyPair() }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("验证 Fleet API 连接并拉取车辆列表:")
            if wizard.vehicles.isEmpty {
                Text("尚未验证").foregroundStyle(.secondary)
            } else {
                Text("找到 \(wizard.vehicles.count) 辆车：\(wizard.vehicles.map(\.name).joined(separator: "、"))")
            }
        }
    }

    private var doneStep: some View {
        Text("设置完成 ✓ 菜单栏见。")
    }
}
