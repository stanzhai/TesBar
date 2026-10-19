import SwiftUI

/// App 组合根：内置凭据（``BuildConfig``，ADR-0004）→ AuthService →
/// FleetTeslaClient → VehicleStore + CommandExecutor。
/// 构建缺少凭据时用 ``OfflineTeslaClient`` 占位，一切调用都报错（UI 引导到设置）。
@available(macOS 14, *)
@MainActor
final class AppServices {
    let store: VehicleStore
    let executor: CommandExecutor
    let coordinator: DangerousCommandCoordinator
    let settings = AppSettings()
    let keys = VCPKeyManager()
    private(set) var client: (any TeslaClient)?

    init() {
        let defaults = UserDefaults.standard

        let executor: CommandExecutor
        if BuildConfig.isComplete {
            let resolver = RegionResolver(defaults: .standard)
            let auth = AuthService()
            let client = FleetTeslaClient(
                transport: RegionRedirectTransport(base: URLSessionTransport(), resolver: resolver),
                auth: auth,
                resolver: resolver,
                defaults: .standard
            )
            self.client = client
            store = VehicleStore(client: client, defaults: defaults)
            executor = CommandExecutor(client: client, notifier: UserNotificationsNotifier())
        } else {
            store = VehicleStore(client: OfflineTeslaClient(), defaults: defaults)
            executor = CommandExecutor(client: OfflineTeslaClient(), notifier: UserNotificationsNotifier())
        }
        self.executor = executor
        coordinator = DangerousCommandCoordinator(
            invoker: ExecutorInvoker(executor: executor, store: store),
            biometrics: LocalAuthGate(),
            gateEnabled: { [settings] in settings.biometricGateEnabled }
        )

        // 故事 33：启动检查 access token，过期前静默续期。
        if let client = self.client as? FleetTeslaClient {
            Task { try? await client.refreshAccessToken() }
        }
        store.startPolling()
    }
}

/// 退出登录编排（ADR-0004）：删 token（AuthService）、清车辆列表/快照/完成标记。
/// VCP 私钥（内置）与已完成的车端配对保留。
@available(macOS 14, *)
extension AppServices {
    @MainActor
    func signOut(keychain: KeychainStore = KeychainStore()) {
        let auth = AuthService(keychain: keychain)
        Task { await auth.signOut() }
        UserDefaults.standard.set(false, forKey: SetupWizard.completeKey)
        UserDefaults.standard.removeObject(forKey: "selectedVehicleID")
        store.clearForSignOut()
    }
}

/// CommandExecutor → CommandInvoking 桥；发令时取当前选中车辆。
@available(macOS 14, *)
@MainActor
final class ExecutorInvoker: CommandInvoking {
    private let executor: CommandExecutor
    private let store: VehicleStore

    init(executor: CommandExecutor, store: VehicleStore) {
        self.executor = executor
        self.store = store
    }

    func invoke(_ command: VehicleCommand) async {
        guard let id = store.selectedVehicleID else { return }
        await executor.execute(command, vehicleID: id)
    }
}

/// 无凭据占位 client（见 ``AppServices``）。
struct OfflineTeslaClient: TeslaClient {
    struct NeedsCredentialsError: LocalizedError {
        var errorDescription: String? { "此构建缺少内置凭据，请用 build-app.sh 重新打包" }
    }

    func listVehicles() async throws -> [VehicleListEntry] { throw NeedsCredentialsError() }
    func vehicleData(id: String) async throws -> VehicleSnapshot { throw NeedsCredentialsError() }
    func wake(id: String) async throws { throw NeedsCredentialsError() }
    func signAndSend(command: VehicleCommand, vehicleID: String) async throws { throw NeedsCredentialsError() }
    func refreshAccessToken() async throws { throw NeedsCredentialsError() }
}

@available(macOS 14, *)
@main
struct TesBarApp: App {
    /// 菜单栏图标：Bundle.main 的 NSImage，手动标记 template 让系统随菜单栏明暗着色。
    private static let menuIcon: NSImage = {
        guard let img = Bundle.main.image(forResource: "MenuIconTemplate") else {
            return NSImage(systemSymbolName: "car.fill", accessibilityDescription: nil)
                ?? NSImage()
        }
        img.isTemplate = true
        return img
    }()
    private var menuIconImage: Image { Image(nsImage: Self.menuIcon) }
    @State private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(services: services)
                .task { await services.store.menuOpened() }
        } label: {
            menuIconImage
        }
        .menuBarExtraStyle(.window)

        Window("TesBar 设置向导", id: SetupWizardView.windowID) {
            SetupWizardWindow()
        }
        .windowResizability(.contentSize)
    }
}

/// 向导独立窗口内容：`@State` 持有 wizard，窗口关闭即释放（重开从持久化恢复进度）。
/// 不再用 MenuBarExtra 面板的 sheet —— 面板对 attached sheet 的尺寸/焦点变化会整体关闭。
@available(macOS 14, *)
private struct SetupWizardWindow: View {
    @State private var wizard = SetupWizard()

    var body: some View {
        SetupWizardView(wizard: wizard)
    }
}
