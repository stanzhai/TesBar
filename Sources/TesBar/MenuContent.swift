import SwiftUI
import MapKit

/// 菜单主内容：状态卡（电量/续航/温度/里程/门锁一行式）+ 车辆切换 + 操作卡（空调/哨兵）+ 设置入口。
/// 危险指令已移除（用户 2026-10 要求精简）；DangerousCommandCoordinator 仍在组合根，设置门禁保留。
/// 睡眠车显示降级卡 + “唤醒”按钮（ADR-0004）。
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

    /// 选中车辆在 list 里的 state（ADR-0004：睡眠/离线显示降级 UI）。
    private var selectedState: String {
        services.store.vehicles
            .first(where: { $0.id == services.store.selectedVehicleID })?.state ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsSetup {
                SetupEntry(services: services)
            } else {
                vehiclePicker
                StatusCard(store: services.store, settings: settings, listState: selectedState)
                CommandCards(services: services, listState: selectedState)
            }
            statusLine
            HStack {
                Button("设置…") { showSettings = true }
                Spacer()
                Button("刷新") { Task { await services.store.refreshNow() } }
                    .disabled(services.store.isLoading)
                Button("退出 TesBar") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .sheet(isPresented: $showSettings) { SettingsView(services: services) }
    }

    private var vehiclePicker: some View {
        Menu {
            ForEach(services.store.vehicles, id: \.id) { vehicle in
                Button(vehicle.name) {
                    Task { await services.store.selectVehicle(vehicle.id) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "car.fill").font(.body).foregroundStyle(.secondary)
                Text(services.store.vehicles.first(where: { $0.id == services.store.selectedVehicleID })?.name ?? "车辆")
                    .font(.headline.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

// MARK: - 状态卡（故事 8–15；ADR-0004 加睡眠降级）

@available(macOS 14, *)
struct StatusCard: View {
    let store: VehicleStore
    @ObservedObject var settings: AppSettings
    /// list 返回的选中车 state（"" = 未知，保守当在线）。
    let listState: String
    @State private var now = Date()

    private var isSleeping: Bool {
        store.snapshot == nil && (listState == "asleep" || listState == "offline")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = store.snapshot {
                hero(snapshot)
                batteryBar(snapshot)
                infoLine(snapshot)
                if let pos = snapshot.position { mapCard(pos) }
                else if snapshot.positionError != nil { positionErrorCard(snapshot.positionError!) }
            } else if store.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在获取车辆数据…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if isSleeping {
                sleepingCard
            } else {
                emptyState
            }
            if let error = store.error, store.snapshot != nil {
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

    /// 睡眠/离线降级卡（ADR-0004）：不唤醒车，无详细数据；显式“唤醒”才取数。
    private var sleepingCard: some View {
        let offline = listState == "offline"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: offline ? "antenna.radiowaves.left.and.right.slash" : "zzz")
                    .font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offline ? "车辆离线" : "睡眠中 · 省电模式").font(.headline)
                    Text("电量、温度等详情需要唤醒车辆后才能获取。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if offline {
                Text("车辆不在线（无网络或长时间停放），唤醒可能失败。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task { await store.wakeNow() }
            } label: {
                HStack(spacing: 6) {
                    if store.isWaking { ProgressView().controlSize(.small) }
                    Text(store.isWaking ? "正在唤醒…" : (offline ? "强制唤醒" : "唤醒车辆"))
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(store.isWaking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
    }

    /// 主视觉：大号电量 + 续航 + 充电状态，右上角车辆状态徽标（已锁/行驶中…）。
    private func hero(_ s: VehicleSnapshot) -> some View {
        let charging = s.charge.state == "Charging"
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(s.charge.batteryPercent)")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("续航 ").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(s.charge.rangeKm.rounded())) km")
                        .monospacedDigit().fontWeight(.semibold)
                        .font(.system(.subheadline, design: .rounded))
                }
                HStack(spacing: 4) {
                    if charging { Image(systemName: "bolt.fill") }
                    Text(chargingText(s))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(charging ? Color.green : Color.secondary)
            }
            Spacer()
            statePill(s)
        }
    }

    /// 电量条：充电/低电用色区分（<10% 红、<20% 橙、充电中绿）。
    private func batteryBar(_ s: VehicleSnapshot) -> some View {
        let charging = s.charge.state == "Charging"
        let color: Color = charging ? .green
            : s.charge.batteryPercent < 10 ? .red
            : s.charge.batteryPercent < 20 ? .orange : .green
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(6, proxy.size.width * Double(s.charge.batteryPercent) / 100))
            }
        }
        .frame(height: 8)
    }

    /// 信息行（非卡片，紧贴电量条下方）：标签灰、数值高亮（rounded 粗体）。
    private func infoLine(_ s: VehicleSnapshot) -> some View {
        let f = settings.useFahrenheit
        return HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.caption2).foregroundStyle(.secondary)
                valueText("车内\(StatusFormatting.temp(celsius: s.climate.insideC, fahrenheit: f) ?? "—")"
                          + " 车外\(StatusFormatting.temp(celsius: s.climate.outsideC, fahrenheit: f) ?? "—")")
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "gauge")
                    .font(.caption2).foregroundStyle(.secondary)
                valueText("总里程 \(Int(s.odometerKm.rounded())) km")
            }
        }
        .font(.footnote)
    }

    /// 地图卡：MapKit 静态快照，车在中心；底部反向地理编码地址行（拿不到时退坐标）。
    private func mapCard(_ pos: VehicleSnapshot.Position) -> some View {
        let coord = CLLocationCoordinate2D(latitude: pos.latitude, longitude: pos.longitude)
        return VStack(alignment: .leading, spacing: 4) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))) {
                Marker("车辆", coordinate: coord)
            }
            .mapStyle(.standard)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 4) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.caption2).foregroundStyle(.secondary)
                LocationText(coord: coord)
            }
        }
    }

    /// 地址行：CLGeocoder 反查（系统服务，免费）；失败/超时退回坐标文本。
    private struct LocationText: View {
        let coord: CLLocationCoordinate2D
        @State private var address: String?

        var body: some View {
            Text(address ?? String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .task {
                    guard address == nil else { return }
                    let placer = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    if let marks = try? await CLGeocoder().reverseGeocodeLocation(placer),
                       let m = marks.first {
                        // 中国区地址习惯：省 市 区 街道（subAdministrativeArea 常为空则跳过）。
                        let parts = [m.administrativeArea, m.locality, m.subLocality, m.thoroughfare, m.name]
                            .compactMap { $0 }.filter { !$0.isEmpty }
                        // 相邻重复去重（直辖市 province==city）。
                        var merged: [String] = []
                        for p in parts where merged.last != p { merged.append(p) }
                        address = merged.isEmpty ? nil : merged.prefix(4).joined()
                    }
                }
        }
    }

    /// 位置获取失败异常卡：图标 + 详细原因。
    private func positionErrorCard(_ reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("车辆位置获取失败").font(.footnote.weight(.semibold))
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 数值高亮文本：按 CJK 边界切段，汉字段小灰、数字/单位段 rounded 粗体，顺序保留。
    private func valueText(_ raw: String) -> Text {
        var result: Text?
        var segment = ""
        var inCJK: Bool?
        func flush() {
            guard !segment.isEmpty else { return }
            let part = inCJK == true
                ? Text(segment).font(.caption2).foregroundStyle(.secondary)
                : Text(segment).monospacedDigit().fontWeight(.semibold)
                    .font(.system(.footnote, design: .rounded))
            result = result.map { $0 + part } ?? part
            segment = ""
        }
        for ch in raw {
            let cjk = ch.unicodeScalars.allSatisfy { $0.properties.isIdeographic || $0.value == 0x2014 }
            if cjk != inCJK { flush(); inCJK = cjk }
            segment.append(ch)
        }
        flush()
        return result ?? Text(raw)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "car").font(.largeTitle).foregroundStyle(.tertiary)
            Text(store.error ?? "暂无数据")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新加载") { Task { await store.refreshNow() } }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var agoText: String {
        guard let updated = store.lastUpdated else { return "" }
        return StatusFormatting.updatedAgo(now.timeIntervalSince(updated))
    }

    /// 车辆状态 + 更新时间（右上角，无背景）：行驶/已锁/未锁/箱门开 + N 分钟前。
    private func statePill(_ s: VehicleSnapshot) -> some View {
        let (text, icon, color): (String, String, Color) = {
            if s.driving { return ("行驶中", "car.fill", .blue) }
            if s.doors.frontTrunkOpen || s.doors.rearTrunkOpen {
                return ("箱门开启", "shippingbox.fill", .orange)
            }
            switch s.doors.locked {
            case .some(true): return ("已锁车", "lock.fill", .green)
            case .some(false): return ("未锁车", "lock.open.fill", .orange)
            case .none: return ("状态未知", "lock.slash", .gray)
            }
        }()
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(text)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            Text(agoText).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func chargingText(_ s: VehicleSnapshot) -> String {
        if s.charge.state == "Charging" {
            return s.charge.minutesToFull.map { "充电中 · 约 \($0) 分钟充满" } ?? "充电中"
        }
        switch s.charge.state {
        case "Complete": return "充电完成"
        case "Disconnected": return "充电枪未连接"
        case "Stopped": return "充电已停止"
        default: return s.charge.state
        }
    }
}

// MARK: - 卡片式指令（ADR-0004：家庭 App 风格替代成对开/关按钮）

/// 开关卡基元：图标 + 名称 + 状态副标题，tap 切换（发开或关指令）。
private struct ToggleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isOn == true ? tint : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn == true ? AnyShapeStyle(tint.opacity(0.15)) : AnyShapeStyle(.quinary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isOn == true ? tint.opacity(0.5) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 14, *)
struct CommandCards: View {
    let services: AppServices
    /// 选中车 list state：睡眠时卡片状态未知（发令仍可，executor 自动唤醒）。
    let listState: String

    @State private var hvacTemp: Double = 21

    private var sleeping: Bool { listState == "asleep" || listState == "offline" }
    var body: some View {
        cardGrid {
            ToggleCard(
                icon: "fanblades.fill",
                title: "空调",
                subtitle: hvacSubtitle,
                isOn: hvacOn,
                tint: .orange
            ) { send(hvacOn == true ? .hvacOff : .hvacOn(temperatureC: hvacTemp)) }

            ToggleCard(
                icon: "eye.fill",
                title: "哨兵",
                subtitle: sentrySubtitle,
                isOn: sentryOn,
                tint: .teal
            ) { send(.sentry(on: !(sentryOn ?? false))) }
        }
    }

    private func cardGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let cards = content()
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            cards
        }
    }

    // MARK: 快照驱动的卡片状态（睡眠时为 nil → 副标题“需唤醒”，tap 仍可发令）

    private var snapshot: VehicleSnapshot? { services.store.snapshot }

    private var hvacOn: Bool? {
        // VehicleSnapshot 未透出 hvac_on（mapper 无该字段）。
        // ponytail: mapper 补该字段后改真值；当前卡片显示为未激活样式。
        nil
    }

    private var hvacSubtitle: String {
        sleeping ? "需唤醒 · \(Int(hvacTemp))°C" : "设定 \(Int(hvacTemp))°C"
    }

    private var sentryOn: Bool? { nil }
    private var sentrySubtitle: String { sleeping ? "需唤醒" : "点击切换" }

    /// 非危险指令直发 executor（无长按/门禁）。
    private func send(_ command: VehicleCommand) {
        guard let id = services.store.selectedVehicleID else { return }
        Task { await services.executor.execute(command, vehicleID: id) }
    }
}
