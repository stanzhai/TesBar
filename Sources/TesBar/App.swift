import SwiftUI

/// App 组合根：凭据 → AuthService → FleetTeslaClient → VehicleStore + CommandExecutor。
/// 凭据未填时用 ``OfflineTeslaClient`` 占位，一切调用都报"请先填写凭据"（UI 引导到设置）。
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
        let id = settings.clientID
        let secret = settings.clientSecret

        let executor: CommandExecutor
        if !id.isEmpty, !secret.isEmpty {
            let resolver = RegionResolver(defaults: .standard)
            let auth = AuthService(clientID: id, clientSecret: secret)
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
        var errorDescription: String? { "请先在设置中填写 Client ID / Secret" }
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
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var services = AppServices()

    var body: some Scene {
        MenuBarExtra("TesBar", systemImage: "car.fill") {
            MenuContent(services: services)
                .task { await services.store.menuOpened() }
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
