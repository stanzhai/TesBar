# 控制功能扩到 4 项（解锁/空调/哨兵/充电）+ 真状态驱动的一行 4 卡 UI

Status: ready-for-human

## 需求

1. 控制从 2 项（空调/哨兵）扩为 4 项：解锁（含锁定）、空调启停、哨兵开关、充电启停。
2. 一行 4 个带 icon 小卡片；显示最新状态（发令前查态/唤醒，发令后确认）；启用状态高亮。

## 改动

- 数据层：`VehicleSnapshot.Climate.hvacOn`（`climate_state.is_climate_on`）、`VehicleSnapshot.Doors.sentryOn`（`vehicle_state.sentry_mode`）；mapper 同步解码，缺失字段 → nil（不猜）。充电中复用现有 `charge.state == "Charging"`。
- `VehicleStore.refreshAfterCommand()`：发令成功后绕过 isOnline 守卫 force 拉 vehicle_data（车刚被 ensureAwake 唤醒但 list state 未更新，refreshNow 会被守卫跳过）。
- UI（`CommandCards`）：2 列 LazyVGrid → 单行 HStack 4 紧凑卡（icon 上、caption 标题、9pt 状态副标题）。卡状态接真值：解锁卡 `doors.locked`（高亮=已锁，icon/title 随状态切换 lock.fill/lock.open.fill），空调 `climate.hvacOn`，哨兵 `doors.sentryOn`，充电 `charge.state == "Charging"`；睡眠时全 nil + 副标题"需唤醒"。
- 解锁是危险指令（ADR-0003）：新 `DangerCard` 走 `services.coordinator` 长按 1s 填充进度 + 可选 Touch ID 门禁（复用 406a6a2 的 DangerButton 手势逻辑）。其余三卡 tap 直发。
- 发令后确认：非危险卡在 `send()` 成功后、危险卡在 `ExecutorInvoker.invoke()` 成功后调 `refreshAfterCommand()`。

## 验证

- 116 测试全绿（+2：mapper 新字段/缺失字段 nil、refreshAfterCommand 绕过睡眠守卫）。
- build-app.sh 打包 + app 运行中。面板冒烟受自动化抢焦点限制，待用户手点确认。

## Comments

- 空调设定温度仍为 @State 21°C 固定值（原行为）；温度选择 UI 未在本期范围。
