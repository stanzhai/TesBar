Status: ready-for-agent
Type: task

# 04 — OAuth token 流程与自动续期

## Summary

Tesla Fleet OAuth：授权码换 token、refresh 续期、401 触发重试。access token 8h、启动检查。spec user stories 1/2/33/34。

## Target

- `Sources/TesBar/AuthService.swift`：
  - ASWebAuthenticationSession 走 `https://auth.tesla.com/oauth2/v3/authorize`（offline_access scope），拿 code 换 `POST /oauth2/v3/token`（client id/secret 用户设置填入）。
  - `refresh()`：refresh token 续期；失败抛 `RefreshTokenInvalid`。
  - token 存取经 02 的 KeychainStore。
  - 401 检测：提供 `authorized(_:)` 包装器——任何 Fleet API 调用 401 时先 refresh 再重试一次；refresh 失效时返回可观察的 `.reauthNeeded` 事件（供通知+引导重登，通知接线在 09/10）。
## Acceptance

- 测试（URLProtocol stub 或注入 transport）：token endpoint 往返解析正确；401→refresh→重试一次成功；refresh 400 → `.reauthNeeded`，不再重试。
- ASWebAuthenticationSession 交互部分不强测（系统 UI），交换逻辑全测。

## Blocked by: 02
