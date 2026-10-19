import SwiftUI

/// 设置（故事 2/36/37）：自启、门禁、温度单位、账户（退出登录，ADR-0004）。
@available(macOS 14, *)
struct SettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @State private var autostart = false
    @State private var confirmSignOut = false
    @State private var isLoggedIn = false
    @Environment(\.dismiss) private var dismiss

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
    }

    var body: some View {
        Form {
            Section("常规") {
                Toggle("登录时启动", isOn: $autostart)
                Picker("温度单位", selection: Binding(
                    get: { settings.useFahrenheit },
                    set: { settings.useFahrenheit = $0 }
                )) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
            }
            Section("危险指令门禁（默认关）") {
                Toggle("Touch ID / 密码门禁", isOn: Binding(
                    get: { settings.biometricGateEnabled },
                    set: { settings.biometricGateEnabled = $0 }
                ))
                Text("开启后，解锁/车门/后备箱/远程启动等危险指令在长按确认后还需通过 Touch ID 或登录密码。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("账户") {
                HStack {
                    Text(isLoggedIn ? "已登录 Tesla 账户" : "未登录")
                        .foregroundStyle(isLoggedIn ? .primary : .secondary)
                    Spacer()
                    if isLoggedIn {
                        Button("退出登录…", role: .destructive) { confirmSignOut = true }
                    }
                }
                Text("退出登录会清除本机的车辆数据与登录凭据；车上的 Virtual Key 配对保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 360)
        .onAppear {
            autostart = AppSettings.currentAutostart()
            isLoggedIn = KeychainStore().hasToken(AuthService.refreshAccount)
        }
        .onChange(of: autostart) { enabled in AppSettings.setAutostart(enabled) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                services.signOut()
                isLoggedIn = false
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除本机的 Tesla 登录凭据与车辆数据。")
        }
    }
}

/// 未登录/无车时的引导入口：打开设置向导完成 OAuth 登录与配对（ADR-0004）。
@available(macOS 14, *)
struct SetupEntry: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isLoggedIn = false

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                services.client == nil ? "此构建缺少内置凭据"
                    : isLoggedIn ? "未找到车辆" : "未完成 Tesla 登录",
                systemImage: "exclamationmark.circle"
            )
            .font(.headline)
            if services.client == nil {
                Text("请用 Scripts/build-app.sh 注入凭据重新打包。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isLoggedIn {
                Text("打开设置向导完成登录，凭据已内置，一步即达。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("列表为空通常是授权时未勾选车辆，重新登录并在授权页勾选你的车。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Accessory app: openWindow orders the window front without activating it,
            // so the wizard appears behind whatever has focus and the menu panel
            // (dismissed on activation loss) stays up. Activate first.
            if services.client != nil {
                Button(isLoggedIn ? "重新运行设置向导…" : "登录 Tesla…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: SetupWizardView.windowID)
                }
                if isLoggedIn {
                    Button("拉取车辆列表") { Task { await services.store.refreshNow() } }
                    if services.store.isLoading { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(.vertical, 4)
        .task {
            // 登录态随时变（退出登录/向导完成）；每次菜单出现都重查。
            while !Task.isCancelled {
                isLoggedIn = KeychainStore().hasToken(AuthService.refreshAccount)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
