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
