Status: ready-for-human
Type: task

# 04 — OAuth token 流程与自动续期

## Summary

Tesla OAuth 2 授权码流 + refresh。研究修正（见 `/Users/stan/Projects/tesbar-research/vcp-fleet-api.md` §4）：token 端点服务器间调用必须用 `https://fleet-auth.prd.cn.vn.cloud.tesla.com/oauth2/v3/token`；authorize 用 `https://auth.tesla.com/oauth2/v3/authorize`；refresh token 单次使用，响应新 refresh 必须立即持久化。

## Target

- `Sources/TesBar/AuthService.swift`，注入 transport（协议或 URLSession 可换）+ KeychainStore：
  - `authorize(clientID:clientSecret:) async throws`：ASWebAuthenticationSession（redirect `https://auth.tesla.com/void/callback`）取 code，`POST token`（form-urlencoded，grant_type=authorization_code，audience=Fleet API base URL，scope 含 `openid offline_access user_data vehicle_device_data vehicle_cmds vehicle_charging_cmds`）。持久化 access+refresh。
  - `refresh() async throws`：grant_type=refresh_token（带 client_id，无 secret）；成功原子替换两个 token。
  - `RefreshTokenInvalid` 错误（token 端点 400/401 或 `login_required`）。
  - `authorized<T>(_ body: () async throws -> T) async throws -> T`：401 时 refresh 一次再重试一次；refresh 失败抛 `ReauthRequired`（可观察事件，供 09/10 引导重登）。
  - access JWT `exp` 启动检查：过期即静默 refresh（user story 33）。
- client id/secret 来自设置（user story 2），不硬编码。

## Acceptance

- 测试（stub transport，脚本化响应）：
  - code 交换请求体字段正确（grant_type/code/client_id/client_secret/audience/redirect_uri）。
  - refresh 成功：新 token 原子落 Keychain。
  - 401 → refresh → 重试成功；refresh 400 → ReauthRequired 且不再重试。
  - 单次使用语义：refresh 响应无新 refresh token 时保留旧值并记 warning（防御）。
- ASWebAuthenticationSession UI 不测。

## Blocked by: 02

## Comments

- Commit `e4919fd` (branch `ticket/04`, merged integration → `ef79def`).
- Files: `Sources/TesBar/AuthService.swift`, `Tests/TesBarTests/AuthServiceTests.swift`.
- Evidence: pre-merge `Test run with 19 tests in 2 suites passed`; post-merge `Test run with 53 tests in 4 suites passed`.
- Tests: exchange request-body fields (grant_type/code/client_id/client_secret/audience/redirect_uri + URL/method/Content-Type); refresh persists both tokens atomically (refresh first — single-use semantics); refresh body has no client_secret; missing-new-refresh keeps old value; 400/401/`login_required` → `RefreshTokenInvalid`; 401 → refresh → retry succeeds; refresh 400 → `ReauthRequired` with no body retry; non-401 passes through; JWT exp parse (valid/missing-exp/non-base64); startup check refreshes only when expired (<60s margin).
- Deviations: `authorized` retries exactly once on 401 only (per ticket); ASWebAuthenticationSession call site compiled (`MainActor` helper + `ASWebAuthenticationPresentationContextProviding` anchor) but not unit-tested, per ticket.
