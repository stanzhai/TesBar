Status: ready-for-agent
Type: task

# 06 — VehicleStore：轮询节奏状态机（@Observable）

## Summary

车辆状态与轮询编排。节奏（ADR-0001，已敲定）：菜单打开即拉；充电中每 1 分钟；平时每 15 分钟且仅车辆在线时拉；不主动唤醒睡眠车。spec user stories 7–15、Testing Decisions 轮询状态机。

## Target

- `Sources/TesBar/VehicleStore.swift`，`@Observable`，依赖注入 `any TeslaClient` + `Clock`（injectable，测试用手动时钟）。
- 状态：`vehicles: [VehicleListEntry]`、`selectedVehicleID`（UserDefaults 持久化默认车，user stories 16/17）、`snapshot: VehicleSnapshot?`、`isLoading`、`error`。
- API：`menuOpened()`（即拉一次）、`selectVehicle(_:)`、`startPolling()`/`stopPolling()`（切换 1min/15min 档位；车在线才拉；睡眠不拉）、`refreshNow()`。
- 离线呈现为状态而非错误（user story 15）。
- `lastUpdated` 驱动"多久前更新"标注（user story 14）。

## Acceptance

- 测试（FakeTeslaClient + 手动时钟）：
  - 菜单打开 → 立即拉一次。
  - 充电中 → advance 60s 触发；平时 → 300s 不拉、900s 拉且仅 online。
  - 睡眠（asleep）→ 不调 vehicleData。
  - 切换车辆 → 拉选中车、持久化选择。
  - 离线 → offline 状态非 error。

## Blocked by: 01
