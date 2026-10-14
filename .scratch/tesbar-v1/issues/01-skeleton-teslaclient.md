Status: ready-for-agent
Type: task

# 01 — 项目骨架：SwiftPM executable + TeslaClient 协议接缝

## Summary

SwiftPM executable package（`TesBar`），`TeslaClient` 协议 + `VehicleSnapshot`/`VehicleListEntry` 值类型定义。这是所有后续 ticket 的编译依赖基座。

## Target

- 新建 `Package.swift`（macOS 13+），`TesBar` executable target。
- `Sources/TesBar/`：`TeslaClient.swift` 定义协议：
  - `listVehicles() async throws -> [VehicleListEntry]`
  - `vehicleData(id:) async throws -> VehicleSnapshot`
  - `wake(id:) async throws`
  - `signAndSend(command:) async throws`（含各指令 payload 枚举 `VehicleCommand`）
  - `refreshAccessToken() async throws`
- 值类型：`VehicleListEntry`（id、name）、`VehicleSnapshot`（电量、续航、充电状态/剩余分钟、内外温度、门窗/锁/后备箱、里程、在线/睡眠、时间戳）。
- `swift build` 与 `swift test` 空跑通过。

## Acceptance

- `swift build`、`swift test`（无测试亦可）零错误。
- 协议方法覆盖 spec Implementation Decisions 的全部接缝：列表、数据、Wake、签名 Command、token 刷新。

## Non-goals

- 任何真 HTTP、Keychain、UI。

## Blocked by: (none)

## Comments

- Commit: e2eddfb (branch `ticket/01`, merged integration tip ddcbc7c — already up to date).
- Files added: `Package.swift` (swift-tools-version 6.0, macOS 13+, executable `TesBar`, test target `TesBarTests`), `Sources/TesBar/main.swift` (placeholder print, replaced by menu UI in ticket 09), `Sources/TesBar/TeslaClient.swift` (protocol `TeslaClient`: listVehicles/vehicleData/wake/signAndSend/refreshAccessToken; `VehicleListEntry`; `VehicleSnapshot` with nested Charge/Climate/Doors + State + odometerKm + timestampMs; `VehicleCommand` with all ticket cases incl. `doorOpen/doorClose(Door)` for frunk/trunk/doors and `isDangerous` per ADR-0003), `Tests/TesBarTests/TeslaClientTests.swift`.
- Test evidence: `swift build` zero errors; `swift test` → "Test run with 1 test in 0 suites passed" (single @Test decodes sample JSON into VehicleSnapshot/VehicleListEntry and checks command payload equality + isDangerous). CLT linker warnings about missing CommandLineTools search paths are environment noise, not package errors.
- Deviations: doors/frunk/trunk modelled as one `Door` enum passed to `doorOpen/doorClose` instead of separate cases (payload carries which door; ADR-0003 dangerous set covered via `isDangerous`). Snapshot JSON field names are the app's canonical shape; ticket 05 maps Fleet API `charge_state`/`climate_state`/`vehicle_state` onto them.
