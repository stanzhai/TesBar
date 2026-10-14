Status: resolved
Type: task

# 05 — FleetTeslaClient：HTTP 实现（VIN 路由 + signed_command + VCP 会话）

## Summary

`TeslaClient` 真实现。研究修正（`/Users/stan/Projects/tesbar-research/vcp-fleet-api.md` §1/§2）：指令端点是 `POST /api/1/vehicles/{vin}/signed_command`（单数、VIN 键，非 vehicle id）；body `{"routable_message": "<base64>"}`；命令认证用 12 的 HMAC 会话（VCSEC/Infotainment 双 domain）；响应 200 仅代表车辆有回复，须解析 `signedMessageStatus`/应用层 payload。数据端点仍可用 vehicle id（`GET /api/1/vehicles`、`/vehicle_data`）。wake 走 VCSEC `RKE_ACTION_WAKE` 或 REST `wake_up`（择一，注明）。

## Target

- `Sources/TesBar/FleetTeslaClient.swift` + `Sources/TesBar/VCP/VCPSession.swift`：
  - 注入：transport、baseURL（08 供）、KeychainStore、VCPKeyManager（03）。
  - `VCPSession`：per-domain 握手缓存——发 `session_info_request`（public_key=C），收 `session_info`（SessionInfo{counter, publicKey, epoch, clock_time}），ECDH 得 K，校验 `HMAC-SHA256(HMAC(K,"session info"), METADATA||session_info)`（constant-time 比较）。session 持久化到 UserDefaults（epoch/counter/clockTime/vehiclePubKey），冷启动免握手。auth fault（INCORRECT_EPOCH/INVALID_TOKEN_OR_COUNTER）携带新 session_info 时更新重试一次。
  - `listVehicles`/`vehicleData`：REST + JSON 解码映射到 VehicleSnapshot（含 charge_state/climate_state/vehicle_state/vehicle_config 字段映射、online/asleep 状态）。
  - `signAndSend(command:)`：12 的 authenticatedCommand → base64 POST。结果解析：非 200 → 错误映射（422 协议不支持、408/503 睡眠离线、401 走 authorized 包装）；200 → 解 RoutableMessage：fault→错误（UNKNOWN_KEY_ID→`virtualKeyNotPaired` 供 07 配对指引）；无 fault 即成功。
  - `VehicleCommand` → domain+protobuf payload 映射表（VCSEC：lock/unlock/remoteStart/wake/actuate trunk|frunk；Infotainment：其余）。
- VehicleListEntry 需补 VIN 字段（改 01 的类型，merge 时保并集）。

## Acceptance

- 测试（stub transport + 假 VCP 会话（注入固定 session/密钥对））：
  - 各指令 → 正确 endpoint、body 含可解码的 RoutableMessage（domain、payload 类型正确）。
  - 握手流程：首令触发 session_info_request，缓存后第二令不再握手。
  - UNKNOWN_KEY_ID fault → 抛 virtualKeyNotPaired。
  - 401 → refresh → 重试（接 04）。
  - vehicleData JSON（真实样例）→ VehicleSnapshot 字段映射正确。
- 串行 `swift test --jobs 1` 全绿。

## Blocked by: 03, 04, 12
