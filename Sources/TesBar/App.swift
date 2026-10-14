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
        let id = defaults.string(forKey: AppSettings.clientIDKey) ?? ""
        let secret = defaults.string(forKey: AppSettings.clientSecretKey) ?? ""

        let executor: CommandExecutor
        if !id.isEmpty, !secret.isEmpty {
            let auth = AuthService(clientID: id, clientSecret: secret)
            let client = FleetTeslaClient(
                transport: RegionRedirectTransport(
                    base: URLSessionTransport(),
                    resolver: RegionResolver(defaults: UserDefaults.standard)
                ),
                auth: auth,
                resolver: RegionResolver(defaults: UserDefaults.standard),
                defaults: UserDefaults.standard
            )
            self.client = client
            store = VehicleStore(client: client, defaults: defaults)
            executor = CommandExecutor(client: client, notifier: UserNotificationsNotifier())
        } else {
            store = VehicleStore(client: OfflineTeslaClient(), defaults: defaults)
            executor = CommandExecutor(client: OfflineTeslaClient(), notifier: UserNotificationsNotifier())
        }
        self.executor = executor

        let settings = self.settings
        coordinator = DangerousCommandCoordinator(
            invoker: ExecutorInvoker(executor: executor, store: store),
            biometrics: LocalAuthGate(),
            gateEnabled: { settings.biometricGateEnabled }
        )
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
    func signAndSend(command: VehicleCommand) async throws { throw NeedsCredentialsError() }
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
    }
}
