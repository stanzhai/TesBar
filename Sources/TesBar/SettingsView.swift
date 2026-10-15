import SwiftUI

/// 设置（故事 2/36/37）：自启、门禁、温度单位、凭据。
/// 凭据保存后需重启应用重建 client —— 文案已注明（完整向导在 ticket 10）。
@available(macOS 14, *)
struct SettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @State private var autostart = false
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
            Section("Tesla 开发者凭据") {
                TextField("Client ID", text: $settings.clientID)
                SecureField("Client Secret", text: $settings.clientSecret)
                Text("保存后重启应用生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 360)
        .onAppear { autostart = AppSettings.currentAutostart() }
        .onChange(of: autostart) { enabled in AppSettings.setAutostart(enabled) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
    }
}

/// 首启入口：凭据未填 / 无车辆时展示 —— 填凭据、（向导在 ticket 10 串联）拉车辆列表。
/// 含 VCP 公钥展示/复制（配合 03 的公钥导出，故事 32 配对指引）。
@available(macOS 14, *)
struct SetupEntry: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @State private var showWizard = false
    @State private var publicKey = ""
    @State private var copied = false
    @State private var isLoggedIn = false

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                services.client == nil ? "请先填写 Tesla 凭据"
                    : isLoggedIn ? "未找到车辆" : "未完成 Tesla 登录",
                systemImage: "exclamationmark.circle"
            )
            .font(.headline)
            if services.client == nil || !isLoggedIn {
                Text("打开设置向导完成登录：凭据已自动回填，进入第 2 步点「登录 Tesla 账户」。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开设置向导…") { showWizard = true }
            } else {
                Button("拉取车辆列表") { Task { await services.store.refreshNow() } }
                if services.store.isLoading { ProgressView().controlSize(.small) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Virtual Key 配对").font(.caption.weight(.semibold))
                Text("若指令返回“虚拟钥匙未配对”，复制下方公钥到 Tesla 开发者后台的 .well-known 托管，并在 App 内完成配对注册。")
                    .font(.caption2).foregroundStyle(.secondary)
                if publicKey.isEmpty {
                    Button("生成 / 查看公钥") {
                        publicKey = (try? services.keys.ensureKeyPair()) ?? "公钥读取失败"
                    }
                } else {
                    ScrollView(.horizontal) {
                        Text(publicKey).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                    .frame(height: 60)
                    Button(copied ? "已复制" : "复制公钥") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(publicKey, forType: .string)
                        copied = true
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            isLoggedIn = KeychainStore().hasToken(AuthService.refreshAccount)
        }
        .sheet(isPresented: $showWizard) {
            SetupWizardView(wizard: SetupWizard())
                .onDisappear { isLoggedIn = KeychainStore().hasToken(AuthService.refreshAccount) }
        }
    }
}
