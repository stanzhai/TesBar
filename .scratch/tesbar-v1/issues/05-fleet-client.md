Status: ready-for-agent
Type: task

# 05 — FleetTeslaClient：HTTP 实现（列表/数据/Wake/签名 Command）

## Summary

`TeslaClient` 协议的真实现：`fleet-api.prd.cn.vn.cloud.tesla.cn`（单区，spec Further Notes）真 HTTP + VCP 签名直发。spec Implementation Decisions 模块划分。

## Target

- `Sources/TesBar/FleetTeslaClient.swift`：
  - base URL 可注入（生产 `fleet-api.prd.cn.vn.cloud.tesla.cn`，测试注入假 server）。
  - `listVehicles`：GET `/api/1/vehicles`。
  - `vehicleData`：GET `/api/1/vehicles/{id}/vehicle_data`。
  - `wake`：POST `/api/1/vehicles/{id}/wake_up`。
  - `signAndSend`：POST `/api/1/vehicles/{id}/signed_commands`（body 含 command JSON + 签名，签名字段按 VCP 规范），私钥签名委托 03 的 VCPKeyManager。
  - JSON 解码到 01 的值类型；401 路径经 04 的 authorized 包装。
  - 解析 `response.result`/`response.reason` 用于失败原因映射（供 07/08）。
- 注入点：transport（URLSession 或协议）、baseURL、clock（时间戳参与签名）。

## Acceptance

- 测试：stub transport 下请求路径/方法/头/签名 body 正确；响应解码为 VehicleSnapshot；401→refresh→重试。

## Non-goals

- 轮询编排、UI。

## Blocked by: 01, 03, 04
