import SwiftUI

/// 菜单主内容：状态卡 + 车辆切换 + 分组指令 + 状态行 + 设置/首启入口。
/// 绑定 VehicleStore（06）/ CommandExecutor（07）/ DangerousCommandCoordinator（09）。
@available(macOS 14, *)
struct MenuContent: View {
    let services: AppServices

    @ObservedObject private var settings: AppSettings
    @ObservedObject private var executor: CommandExecutor
    @State private var showSettings = false

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _executor = ObservedObject(wrappedValue: services.executor)
    }

    private var needsSetup: Bool {
        services.client == nil || services.store.vehicles.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsSetup {
                SetupEntry(services: services)
            } else {
                vehiclePicker
                StatusCard(store: services.store, settings: settings)
                CommandGroups(services: services)
            }
            statusLine
            HStack {
                Button("设置…") { showSettings = true }
                Spacer()
                Button("刷新") { Task { await services.store.refreshNow() } }
                    .disabled(services.store.isLoading)
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .sheet(isPresented: $showSettings) { SettingsView(services: services) }
    }

    private var vehiclePicker: some View {
        Picker("车辆", selection: Binding(
            get: { services.store.selectedVehicleID ?? "" },
            set: { id in Task { await services.store.selectVehicle(id) } }
        )) {
            ForEach(services.store.vehicles, id: \.id) { vehicle in
                Text(vehicle.name).tag(vehicle.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusLine: some View {
        switch executor.status {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("发送中…").font(.caption).foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("已发送", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .failed(let reason, let retryable):
            HStack {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
                if retryable {
                    Button("重试") { Task { await executor.retry() } }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - 状态卡（故事 8–15）

@available(macOS 14, *)
struct StatusCard: View {
    let store: VehicleStore
    @ObservedObject var settings: AppSettings
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = store.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(snapshot.charge.batteryPercent)%")
                        .font(.system(size: 28, weight: .bold))
                    VStack(alignment: .leading) {
                        Text("\(Int(snapshot.charge.rangeKm.rounded())) km").font(.title3)
                        Text(chargingText(snapshot)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    stateBadge(snapshot.state)
                }
                Text(climateText(snapshot)).font(.caption).foregroundStyle(.secondary)
                Text(StatusFormatting.doors(snapshot.doors)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Image(systemName: "gauge")
                    Text("里程 \(Int(snapshot.odometerKm.rounded())) km")
                    Spacer()
                    Text(agoText)
                }
                .font(.caption2).foregroundStyle(.tertiary)
            } else if store.isLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("加载中…").font(.callout) }
            } else {
                Text(store.error ?? "暂无数据").font(.callout).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .task {
            // “多久前更新”每 15s 自刷新（故事 14）。
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private var agoText: String {
        guard let updated = store.lastUpdated else { return "" }
        return StatusFormatting.updatedAgo(now.timeIntervalSince(updated))
    }

    @ViewBuilder private func stateBadge(_ state: VehicleSnapshot.State) -> some View {
        // 离线是状态不是错误（故事 15）：灰字，不报红。
        switch state {
        case .online: Text("在线").font(.caption).foregroundStyle(.green)
        case .asleep: Text("睡眠").font(.caption).foregroundStyle(.secondary)
        case .offline: Text("离线").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chargingText(_ s: VehicleSnapshot) -> String {
        if s.charge.state == "Charging", let minutes = s.charge.minutesToFull {
            return "充电中 · 约 \(minutes) 分钟充满"
        }
        return s.charge.state
    }

    private func climateText(_ s: VehicleSnapshot) -> String {
        let inside = StatusFormatting.temp(celsius: s.climate.insideC, fahrenheit: settings.useFahrenheit)
        let outside = StatusFormatting.temp(celsius: s.climate.outsideC, fahrenheit: settings.useFahrenheit)
        return "车内 \(inside ?? "—") · 车外 \(outside ?? "—")"
    }
}

// MARK: - 分组指令（故事 18–26）

@available(macOS 14, *)
struct CommandGroups: View {
    let services: AppServices

    @State private var hvacTemp: Double = 21
    @State private var chargeLimit: Double = 80
    @State private var seatLevel: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupBox("空调") {
                VStack(spacing: 4) {
                    Stepper("温度 \(Int(hvacTemp))°C", value: $hvacTemp, in: 15...28)
                    HStack {
                        Button("开空调") { send(.hvacOn(temperatureC: hvacTemp)) }
                        Button("关空调") { send(.hvacOff) }
                    }
                    HStack {
                        Button("除霜") { send(.defrost(on: true)) }
                        Button("停止除霜") { send(.defrost(on: false)) }
                    }
                    HStack {
                        Stepper("座椅加热 L\(Int(seatLevel))", value: $seatLevel, in: 0...3)
                        Button("设置") { send(.seatHeat(level: Int(seatLevel))) }
                    }
                }
            }
            GroupBox("找车 / 安全") {
                VStack(spacing: 4) {
                    HStack {
                        Button("鸣笛") { send(.horn) }
                        Button("闪灯") { send(.flashLights) }
                        Button("哨兵开") { send(.sentry(on: true)) }
                        Button("哨兵关") { send(.sentry(on: false)) }
                    }
                }
            }
            GroupBox("充电") {
                VStack(spacing: 4) {
                    HStack {
                        Button("开充电口") { send(.chargePort(open: true)) }
                        Button("关充电口") { send(.chargePort(open: false)) }
                        Button("开始充电") { send(.startCharge) }
                        Button("停止充电") { send(.stopCharge) }
                    }
                    HStack {
                        Stepper("限值 \(Int(chargeLimit))%", value: $chargeLimit, in: 50...100, step: 5)
                        Button("设置") { send(.setChargeLimit(percent: Int(chargeLimit))) }
                    }
                }
            }
            GroupBox("危险指令 · 长按 1 秒") {
                VStack(spacing: 4) {
                    HStack {
                        DangerButton("解锁", command: .unlock, coordinator: services.coordinator)
                        DangerButton("锁车", command: .lock, coordinator: services.coordinator)
                        DangerButton("远程启动", command: .remoteStart, coordinator: services.coordinator)
                    }
                    HStack {
                        DangerButton("开后备箱", command: .doorOpen(.trunk), coordinator: services.coordinator)
                        DangerButton("关后备箱", command: .doorClose(.trunk), coordinator: services.coordinator)
                        DangerButton("开前备箱", command: .doorOpen(.frunk), coordinator: services.coordinator)
                        DangerButton("关前备箱", command: .doorClose(.frunk), coordinator: services.coordinator)
                    }
                    // 车门本身不支持远程开闭（research §5）；门的开闭状态见上方状态卡。
                }
            }
        }
    }

    /// 非危险指令直发 executor（无长按/门禁）。
    private func send(_ command: VehicleCommand) {
        guard let id = services.store.selectedVehicleID else { return }
        Task { await services.executor.execute(command, vehicleID: id) }
    }
}

/// 危险指令按钮：按下/松手驱动 coordinator，50ms tick 喂 ConfirmGate；
/// 进度条读 coordinator.confirmGate.state（长按达 1s 发令，门禁开启时叠加认证）。
@available(macOS 14, *)
struct DangerButton: View {
    let title: String
    let command: VehicleCommand
    @ObservedObject var coordinator: DangerousCommandCoordinator

    @State private var pressing = false
    @State private var timer: Timer?

    init(_ title: String, command: VehicleCommand, coordinator: DangerousCommandCoordinator) {
        self.title = title
        self.command = command
        self.coordinator = coordinator
    }

    var body: some View {
        let progress: Double
        if case .pressing(let p) = coordinator.confirmGate.state { progress = p } else { progress = 0 }

        return Button(action: {}) {
            Text(title)
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: proxy.size.width * min(progress, 1))
                    }
                    .allowsHitTesting(false)
                )
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressing else { return }
                    pressing = true
                    Task { await coordinator.beginPress(command) }
                    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                        Task { @MainActor in await coordinator.tick(Date()) }
                    }
                }
                .onEnded { _ in
                    stopTimer()
                    coordinator.endPress()
                    pressing = false
                }
        )
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
