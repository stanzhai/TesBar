Status: ready-for-agent
Type: task

# 08 — Fleet API 域解析：421/Alt-Svc 重定向 + 手动覆盖

## Summary

研究修正（`/Users/stan/Projects/tesbar-research/vcp-fleet-api.md` §0.3/§1）：`fleet_api_metadata` 端点不存在。真实机制：请求错误区域时 Fleet API 返回 `421` + `Alt-Svc: h2=<正确host>`，SDK 据此重试。实现：缓存解析出的 baseURL，421 时按 Alt-Svc 切换并持久化；设置里可手动覆盖。

## Target

- `Sources/TesBar/RegionResolver.swift`：
  - 默认 `https://fleet-api.prd.cn.vn.cloud.tesla.cn`（spec 单区）；持久化 UserDefaults。
  - `handle421(response:)`：解析 `Alt-Svc` 的 `h2=host` → 更新缓存（schema 保留 https）。
  - 手动覆盖（设置 string，空=自动）优先级最高。
- 接入 05：FleetTeslaClient 收 421 时先问 resolver 再重试一次。

## Acceptance

- 测试（stub transport/headers）：
  - 421 + `Alt-Svc: h2=fleet-api.prd.na.vn.cloud.tesla.com` → baseURL 更新并缓存、重试用新域。
  - 无 Alt-Svc 的 421 → 原错误上抛。
  - 手动覆盖生效且不被 421 改写。

## Blocked by: 05
