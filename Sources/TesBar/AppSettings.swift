import AppKit
import ServiceManagement

/// LSUIElement：无 Dock 图标（Info.plist 由 ticket 11 打包时补 LSUIElement=true；
/// SPM 可执行进程在无 plist 情况下用 ActivationPolicy.accessory 兜底，故事 36）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 设置持久化（UserDefaults）+ 自启开关（SMAppService，故事 36/37）。
@available(macOS 14, *)
@MainActor
final class AppSettings: ObservableObject {
    static let clientIDKey = SetupWizard.clientIDKey
    static let clientSecretAccount = SetupWizard.clientSecretAccount
    static let tempUnitKey = "temperatureUnitFahrenheit"
    static let gateKey = "biometricGateEnabled"
    private let keychain = KeychainStore()


    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }
    /// client secret 只存 Keychain（user story 35）。
    @Published var clientSecret: String {
        didSet { try? keychain.saveToken(clientSecret, for: Self.clientSecretAccount) }
    }
    /// true = °F。
    @Published var useFahrenheit: Bool {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: Self.tempUnitKey) }
    }
    /// Touch ID/PIN 门禁，默认关（ADR-0003）。
    @Published var biometricGateEnabled: Bool {
        didSet { UserDefaults.standard.set(biometricGateEnabled, forKey: Self.gateKey) }
    }
    /// 登录自启（SMAppService）。开关切换注册/注销。
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            Self.setAutostart(launchAtLogin)
        }
    }

    init() {
        let d = UserDefaults.standard
        clientID = d.string(forKey: Self.clientIDKey) ?? ""
        clientSecret = (try? keychain.readToken(Self.clientSecretAccount)) ?? ""
        useFahrenheit = d.bool(forKey: Self.tempUnitKey)
        biometricGateEnabled = d.bool(forKey: Self.gateKey)
        launchAtLogin = d.bool(forKey: "launchAtLogin")
    }

    /// SMAppService 注册/注销。CI 无 GUI 下 .openError 也只吞掉，开关状态照存。
    static func setAutostart(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // 状态与实际可能不同步；下次打开设置会重新读。ponytail: 不做重试/提示
        }
    }

    /// 实际自启状态（SMAppService 真值优先，故事 36）。
    static func currentAutostart() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}
