Status: resolved
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


## Comments

### Impl08 — 2026-10-14

- Commits (branch `ticket/08`): `08-region-resolver: RegionResolver (421/Alt-Svc h2=host switch + UserDefaults cache + manual override wins) and RegionRedirectTransport retry-once middleware`.
- Files: `Sources/TesBar/RegionResolver.swift` (new), `Tests/TesBarTests/RegionResolverTests.swift` (new).
- `RegionResolver`: `static let defaultBaseURL = https://fleet-api.prd.cn.vn.cloud.tesla.cn`; injectable `UserDefaults`; `baseURL` = override (non-empty) > cached 421 URL > default; `setOverride("")`/`setOverride(url)` manages the settings string (empty = auto); `handle421(headers:)` parses `Alt-Svc: h2=<host>` (case-insensitive header lookup, quoted authority + multi-entry tolerated), rebuilds `https://<host>`, persists under `fleetAPIBaseURL` — never writes when an override is active.
- Transport seam: `RegionRedirectTransport` wraps any `HTTPExecuting`; 421 + usable Alt-Svc → rewrite scheme/host/port from the resolver's base (path/query/body preserved) and retry exactly once; 421 without Alt-Svc → `HTTPStatusError(421)`; non-421 passed through untouched. Ticket 05's `FleetTeslaClient` should send through this wrapper (it composes with 04's `authorized` 401-retry).
- Tests (9 new, `RegionResolverTests`, private `ScriptedHTTPTransport` — no name clash with the shared fakes): default base when nothing cached; 421+Alt-Svc updates+persists (fresh resolver over same defaults sees it); Alt-Svc variants (upper-case header, quoted+ma=, h3,h2 list, h3-only → nil, empty/absent → nil); override wins and not clobbered by 421 (cache stays untouched — clearing override falls back to default); empty override = auto; 421 redirect retries once against new host with path/query preserved; 421 without Alt-Svc rethrows with exactly one call; 404 passes through (one call, resolver untouched); override-active 421 retry goes to override base not Alt-Svc host.
- Verification: `swift build --jobs 1` clean; `swift test --jobs 1` → `Test run with 62 tests in 5 suites passed` (53 pre-existing + 9 new; hit the known TestingMacros plugin-load flake once, clean retry). Merged `integration/tesbar-v1` before starting (was already up to date at `3cff883`).
- Deviations: none. `RegionResolver` is a lock-guarded final class (`@unchecked Sendable` — UserDefaults lacks a Sendable overlay but is documented thread-safe), not an actor, so `RegionRedirectTransport` stays a plain struct wrapping the existing `HTTPExecuting` seam.