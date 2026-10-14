Status: ready-for-agent
Type: task

# 08 — Fleet API 域：公开 API 查域名 + 设置项

## Summary

生产域名不是硬编码：Tesla 公开 API `https://fleet-api.prd.cn.vn.cloud.tesla.cn/api/1/vehicles/fleet_api_metadata` 返回该 account 可用 region 域名，启动时查询并缓存；用户设置里可手动覆盖。spec Further Notes（单区但凭据分区）。

## Target

- `Sources/TesBar/RegionResolver.swift`：`resolve() async throws -> URL`，先读缓存（UserDefaults），miss 时 GET fleet_api_metadata（bearer token）取 `fleet_api_base_url`；失败回退生产默认域名 `fleet-api.prd.cn.vn.cloud.tesla.cn`。
- FleetTeslaClient 的 baseURL 由它供给（改 05 的注入即可，若 05 已默认生产域名则此 ticket 只是把解析器接入）。
- 设置项：手动覆盖域名（string，空=自动）。

## Acceptance

- 测试（stub transport）：metadata 响应 → baseURL 更新并缓存；失败 → 回退默认；手动覆盖优先。

## Blocked by: 04, 05
