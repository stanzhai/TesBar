import SwiftUI
import MapKit

/// 菜单主内容：车辆切换（右侧信息列：状态/里程/温度/更新时间）+ 状态卡（电量 + 电量条下充电枪/续航 + 地图）+ 操作卡 + 设置入口。
/// 解锁（含锁车）走 DangerousCommandCoordinator 长按门禁（ADR-0003）；其余 tap 直发。
/// 睡眠车显示降级卡 + “唤醒”按钮（ADR-0004）。
@available(macOS 14, *)
struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    let services: AppServices

    @ObservedObject private var settings: AppSettings
    @ObservedObject private var executor: CommandExecutor

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
                HStack(alignment: .firstTextBaseline) {
                    vehiclePicker
                    Spacer(minLength: 8)
                    statusBadge
                }
                StatusCard(store: services.store, settings: settings, listState: selectedState)
                CommandCards(services: services, listState: selectedState)
            }
            HStack {
                Button("设置…") {
                    // 面板挂 sheet 会把 popover 管线打死（同 cb9307e 向导问题）：
                    // sheet 关闭后面板僵死——不自动关、不重绘、圆角丢失。
                    // 设置放独立 Window，面板不再挂任何 sheet。
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: SettingsView.windowID)
                }
                Spacer()
                Button(services.store.isWaking ? "唤醒中…" : "刷新") {
                    Task { await services.store.wakeAndRefresh() }
                }
                .disabled(services.store.isWaking)
                Button("退出 TesBar") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 340)
        .background(PanelCornerKeeper())
    }
}

@available(macOS 14, *)
extension MenuContent {
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

    /// 车辆名称行右端的状态徽标：发送中/已发送/指令失败原因/数据获取错误。
    /// 长原因换行展示；与车辆名同占首行（错误时面板被撑高，属预期）。
    @ViewBuilder private var statusBadge: some View {
        switch executor.status {
        case .idle:
            // 睡眠/离线的取数失败是预期行为（isOnline 守卫旁路的 408/超时），
            // 状态卡的"数据为 X 前"角标已覆盖，不重复报错。
            if let error = services.store.error, selectedState != "asleep" && selectedState != "offline" {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sending:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("发送中…").font(.caption2).foregroundStyle(.secondary)
            }
        case .succeeded:
            Label("已发送", systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.green)
        case .failed(let reason, let retryable):
            HStack(alignment: .top, spacing: 4) {
                Label {
                    Text(reason)
                        // 指令失败原因可能很长（带 API 响应体），允许完整换行。
                        .font(.caption2).foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.red)
                }
                if retryable {
                    Button("重试") { Task { await executor.retry() } }
                        .controlSize(.mini)
                        .font(.caption2)
                }
            }
        }
    }
}
// MARK: - 右上角信息列（与车辆名称对齐）

/// 车辆名称右侧从上到下：车辆状态、总里程、温度。
/// 内容与样式平移自原 statePill / infoLine，仅换位置。
@available(macOS 14, *)
private struct VehicleInfoColumn: View {
    @ObservedObject var settings: AppSettings
    let snapshot: VehicleSnapshot

    var body: some View {
        // 撑满 hero 高度、3 行等间距分布：首行顶=电量数字顶、末行底=续航底（原位置）。
        VStack(alignment: .trailing, spacing: 0) {
            stateRow
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "gauge")
                    .font(.caption2).foregroundStyle(.secondary)
                valueText("总里程 \(Int(snapshot.odometerKm.rounded())) km")
            }
            .font(.footnote)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.caption2).foregroundStyle(.secondary)
                valueText(tempText)
            }
            .font(.footnote)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tempText: String {
        let f = settings.useFahrenheit
        return "车内\(StatusFormatting.temp(celsius: snapshot.climate.insideC, fahrenheit: f) ?? "—")"
            + " 车外\(StatusFormatting.temp(celsius: snapshot.climate.outsideC, fahrenheit: f) ?? "—")"
    }


    /// 车辆状态（原 statePill）：行驶/已锁/未锁/箱门开。
    private var stateRow: some View {
        let (text, icon, color): (String, String, Color) = {
            if snapshot.driving { return ("行驶中", "car.fill", .blue) }
            if snapshot.doors.frontTrunkOpen || snapshot.doors.rearTrunkOpen {
                return ("箱门开启", "shippingbox.fill", .orange)
            }
            switch snapshot.doors.locked {
            case .some(true): return ("已锁车", "lock.fill", .green)
            case .some(false): return ("未锁车", "lock.open.fill", .orange)
            case .none: return ("状态未知", "lock.slash", .gray)
            }
        }()
        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }
}

@available(macOS 14, *)
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
                // hero 行：电量数字 38pt 行框顶有留白，信息列下移 ~4pt 使
                // 状态行字形顶对齐数字字形顶；Spacer 重新均分剩余空间。
                HStack(alignment: .top) {
                    hero(snapshot)
                    Spacer(minLength: 8)
                    VehicleInfoColumn(settings: settings, snapshot: snapshot)
                        .padding(.top, 9)
                }
                batterySection(snapshot)
                if let pos = snapshot.position { mapCard(pos) }
                else if snapshot.positionError != nil { positionErrorCard(snapshot.positionError!) }
                // 旧数据保留显示（方案 1）：车睡眠/离线但还有上次快照时，
                // 不清数据，只提示数据是旧的 + 车辆状态。
                if listState == "asleep" || listState == "offline" {
                    let label = listState == "offline" ? "车辆离线" : "车辆睡眠中"
                    if let updated = store.lastUpdated {
                        Label(
                            "\(label) · 数据为 \(StatusFormatting.updatedAgo(now.timeIntervalSince(updated)))",
                            systemImage: "zzz"
                        )
                        .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Label(label, systemImage: "zzz")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else if store.isLoading || store.isWaking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.isWaking ? "正在唤醒车辆…" : "正在获取车辆数据…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else if isSleeping {
                sleepingCard
            } else {
                emptyState
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

    /// 主视觉：大号电量百分比 + 下方续航（状态/里程/温度在车辆名右侧列）。
    private func hero(_ s: VehicleSnapshot) -> some View {
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

    /// 电量条区：电量条，左下角充电枪状态，右下角更新时间。
    private func batterySection(_ s: VehicleSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            batteryBar(s)
            HStack(alignment: .firstTextBaseline) {
                chargingRow(s)
                Spacer()
                Text(agoText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 充电枪插入状态（电量条左下角，原 hero 第三行）：充电中绿色 + bolt。
    private func chargingRow(_ s: VehicleSnapshot) -> some View {
        let charging = s.charge.state == "Charging"
        return HStack(spacing: 4) {
            if charging { Image(systemName: "bolt.fill") }
            Text(chargingText(s))
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(charging ? Color.green : Color.secondary)
    }

    private var agoText: String {
        guard let updated = store.lastUpdated else { return "" }
        return StatusFormatting.updatedAgo(now.timeIntervalSince(updated))
    }

    /// 地图卡：MapKit 静态快照，车在中心；底部反向地理编码地址行（拿不到时退坐标）。
    /// 点地址行 → 系统默认地图软件从当前位置导航到车辆（Maps URL daddr + 当前位置 saddr）。
    @State private var isHoveringAddress = false
    private func mapCard(_ pos: VehicleSnapshot.Position) -> some View {
        let coord = CLLocationCoordinate2D(latitude: pos.latitude, longitude: pos.longitude)
        return VStack(alignment: .leading, spacing: 4) {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: coord,
                span: MKCoordinateSpan(latitudeDelta: 0.0025, longitudeDelta: 0.0025)))) {
                Marker("车辆", coordinate: coord)
            }
            .mapStyle(.standard)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Button {
                // saddr 缺省 = 地图 app 用当前位置；daddr= 目的地（GCJ 坐标直接传，
                // 中国版 Maps 底图同坐标系）。系统按默认地图 app 打开。
                var comps = URLComponents(string: "https://maps.apple.com/maps")!
                comps.queryItems = [
                    URLQueryItem(name: "daddr", value: "\(pos.latitude),\(pos.longitude)"),
                    URLQueryItem(name: "dirflg", value: "d"),
                ]
                if let url = comps.url { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption2)
                        .foregroundStyle(isHoveringAddress ? Color.accentColor : .secondary)
                    LocationText(coord: coord, linkLook: isHoveringAddress)
                    Image(systemName: "location.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isHoveringAddress ? Color.accentColor : .secondary)
                }
                .onHover { hovering in
                    // macOS SwiftUI 无 .pointer 光标，onHover 手动切 pointing hand。
                    isHoveringAddress = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// 地址行：CLGeocoder 反查（系统服务，免费）；失败/超时退回坐标文本。
    private struct LocationText: View {
        let coord: CLLocationCoordinate2D
        /// hover 时按超链接样式渲染（accent 色 + 下划线）。
        var linkLook: Bool = false
        @State private var address: String?

        var body: some View {
            Text(address ?? String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                .font(.caption2)
                .foregroundStyle(linkLook ? Color.accentColor : .secondary)
                .underline(linkLook, pattern: .solid)
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
                Text(reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }


    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "car").font(.largeTitle).foregroundStyle(.tertiary)
            Text("暂无数据")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新加载") { Task { await store.refreshNow() } }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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

// MARK: - 卡片式指令（ADR-0004：家庭 App 风格；4 卡一行：解锁/空调/哨兵/充电）

/// 开关卡基元：图标 + 名称 + 状态副标题，tap 切换（发开或关指令）。
/// 紧凑版：icon 顶部居中，caption 标题，4 列一排（面板 340pt → 每卡 ~74pt）。
private struct ToggleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool?
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isOn == true ? tint : .secondary)
                Text(title).font(.caption2.weight(.semibold))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isOn == true
                            ? AnyShapeStyle(tint.opacity(0.15))
                            : AnyShapeStyle(.quinary)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isOn == true ? tint.opacity(0.5) : .clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovering ? 1.05 : 1)
            .animation(.snappy(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            // macOS SwiftUI 无 .pointer 光标，onHover 手动切 pointing hand。
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// 解锁确认卡（ADR-0003 精简版）：tap 弹确认（unlock 是危险指令），锁车无需确认。
/// 视觉同 ToggleCard；确认用 confirmationDialog（挂在菜单面板外的独立设置窗口之外，
/// 面板本身不能挂 sheet —— 见 issue 13；confirmationDialog 走 popover 安全路径）。
private struct UnlockCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isOn: Bool?
    let tint: Color
    /// 已锁 → tap 弹确认后发 unlock；未锁 → tap 直接发 lock。
    let locked: Bool?
    let send: (VehicleCommand) -> Void

    @State private var confirmingUnlock = false

    var body: some View {
        ToggleCard(icon: icon, title: title, subtitle: subtitle, isOn: isOn, tint: tint) {
            if locked == true {
                confirmingUnlock = true
            } else {
                // 锁车非危险指令，无需确认；状态未知（睡眠/无数据）默认按解锁流程确认。
                send(.lock)
            }
        }
        .confirmationDialog(
            "解锁车辆？",
            isPresented: $confirmingUnlock,
            titleVisibility: .visible
        ) {
            Button("解锁", role: .destructive) { send(.unlock) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("车门将全部解锁，任何人可进入车内。")
        }
    }
}

@available(macOS 14, *)
struct CommandCards: View {
    let services: AppServices
    /// 选中车 list state：睡眠时卡片状态未知（发令仍可，executor 自动唤醒）。
    let listState: String

    private var sleeping: Bool { listState == "asleep" || listState == "offline" }

    var body: some View {
        HStack(spacing: 6) {
            // 解锁是危险指令（ADR-0003 精简为弹窗确认）：已锁 → 确认弹窗后解锁；
            // 未锁 → 直接锁车（非危险）。状态未知按锁车路径（保守发 lock）。
            UnlockCard(
                icon: locked == true ? "lock.fill" : "lock.open.fill",
                title: locked == true ? "锁定" : "解锁",
                subtitle: lockSubtitle,
                isOn: locked,
                tint: .indigo,
                locked: locked,
                send: send
            )
            ToggleCard(
                icon: "fanblades.fill",
                title: "空调",
                subtitle: hvacSubtitle,
                isOn: hvacOn,
                tint: .orange
            ) { send(hvacOn == true ? .hvacOff : .hvacOn) }
            ToggleCard(
                icon: "eye.fill",
                title: "哨兵",
                subtitle: sentrySubtitle,
                isOn: sentryOn,
                tint: .teal
            ) { send(.sentry(on: !(sentryOn ?? false))) }
            ToggleCard(
                icon: "bolt.fill",
                title: "充电",
                subtitle: chargeSubtitle,
                isOn: chargingOn,
                tint: .green
            ) { send(chargingOn == true ? .stopCharge : .startCharge) }
        }
    }

    // MARK: 快照驱动的卡片状态（睡眠时为 nil → 副标题“需唤醒”，tap 仍可发令）

    private var snapshot: VehicleSnapshot? { services.store.snapshot }

    private var locked: Bool? {
        sleeping ? nil : snapshot?.doors.locked
    }

    private var lockSubtitle: String {
        switch locked {
        case .some(true): "已锁"
        case .some(false): "未锁"
        case .none: sleeping ? "需唤醒" : "未知"
        }
    }

    private var hvacOn: Bool? {
        sleeping ? nil : snapshot?.climate.hvacOn
    }

    private var hvacSubtitle: String {
        if sleeping { return "需唤醒" }
        return hvacOn == true ? "开启中" : "已关闭"
    }

    private var sentryOn: Bool? {
        sleeping ? nil : snapshot?.doors.sentryOn
    }

    private var sentrySubtitle: String {
        if sleeping { return "需唤醒" }
        return sentryOn == true ? "开启中" : "已关闭"
    }

    private var chargingOn: Bool? {
        sleeping ? nil : (snapshot?.charge.state == "Charging" ? true : (snapshot == nil ? nil : false))
    }

    private var chargeSubtitle: String {
        if sleeping { return "需唤醒" }
        return chargingOn == true ? "充电中" : "未充电"
    }

    /// 非危险指令直发 executor（无长按/门禁）；成功后带预期变化拉新快照，
    /// 后端滞后时最多再轮询 4×2s 等状态翻转（状态卡/右上角徽标及时更新）。
    private func send(_ command: VehicleCommand) {
        guard let id = services.store.selectedVehicleID else { return }
        Task {
            await services.executor.execute(command, vehicleID: id)
            if services.executor.status == .succeeded {
                await services.store.refreshAfterCommand(expected: command)
            }
        }
    }
}

// MARK: - 面板圆角保活（issue 13 同族缺陷）

/// MenuBarExtra(.window) 面板内容在打开期间高度跳变（睡眠降级卡 ↔ 快照 hero+地图）
/// 触发 live resize，SwiftUI 会丢 popover 圆角/材质 mask → 矩形。零尺寸锚点挂窗口上，
/// 每次 frame/resize/重开后重设 contentView layer 的圆角。
@available(macOS 14, *)
private struct PanelCornerKeeper: NSViewRepresentable {
    final class KeeperView: NSView {
        private var observed: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            NotificationCenter.default.removeObserver(self)
            observed = newWindow
            guard let window = newWindow else { return }
            arm(window)
            startObserving(window)
            reapply(on: window)
            // resize 后 SwiftUI 可能整套换 contentView 子树，下一帧兜底再刷。
            Task { @MainActor in
                guard let window = self.observed else { return }
                self.arm(window)
                self.reapply(on: window)
            }
        }

        private func arm(_ window: NSWindow) {
            window.contentView?.wantsLayer = true
            // frameDidChange 默认不发通知，必须显式打开。
            window.contentView?.postsFrameChangedNotifications = true
        }

        private func startObserving(_ window: NSWindow) {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(refresh),
                           name: NSView.frameDidChangeNotification, object: window.contentView)
            nc.addObserver(self, selector: #selector(refresh),
                           name: NSWindow.didResizeNotification, object: window)
            // 面板关闭重开（popover 重启）也要重设。
            nc.addObserver(self, selector: #selector(refresh),
                           name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func refresh() {
            MainActor.assumeIsolated {
                guard let window = observed else { return }
                arm(window)
                reapply(on: window)
            }
        }

        private func reapply(on window: NSWindow) {
            guard let layer = window.contentView?.layer else { return }
            layer.masksToBounds = true
            layer.cornerRadius = 10
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ nsView: KeeperView, context: Context) {}
}
