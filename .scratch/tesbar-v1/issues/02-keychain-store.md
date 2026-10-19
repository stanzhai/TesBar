Status: resolved
Type: task

# 02 — KeychainStore：token/私钥存 Keychain

## Summary

`KeychainStore`：access/refresh token 与 VCP 私钥（PEM 字节）的读写，服务名 `com.tesbar.app`。spec user stories 3/35。

## Target

- `Sources/TesBar/KeychainStore.swift`，API：`saveToken(_:_:)` / `readToken(_:)` / `deleteToken(_:)`、`savePrivateKey(_:)` / `readPrivateKey()` / `deletePrivateKey()`。
- SecItem CRUD，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
- 失败抛 typed error（`KeychainError`），不吞。

## Acceptance

- 单元测试：save→read 往返、delete 后 read 失败、错误类型正确。测试环境（无宿主 App、非主线程 caller 亦可）下可用。

## Comments

- Commit: a5546ee（分支 `ticket/02`，基 ddcbc7c，merge `integration/tesbar-v1` already up to date）。
- 新增：`Sources/TesBar/KeychainStore.swift`（`KeychainStore` + `KeychainError`，service `com.tesbar.app`，token 三方法 + 私钥三方法，SecItem CRUD，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，save 走 update-else-add，delete 幂等，非 Keychain item 错误抛 `KeychainError.unhandled(OSStatus)`）。
- 测试：`Tests/TesBarTests/KeychainStoreTests.swift`，真 Keychain（ticket 记载例外）。5 tests / 1 suite 全过：save→read 往返（token+私钥）、delete 后 read 抛 `itemNotFound`、缺 item 读抛 `itemNotFound`、重复 save 覆盖、非主线程 caller。账户名带 UUID 后缀 + 测试后 delete，重跑绿（已验证两连跑，`security find-generic-password -s com.tesbar.app` 无残留）。
- 偏差：本分支无 Package.swift（ticket 01 并行未落地），按 ticket 01 文本自建最小骨架（Package.swift + TeslaClient.swift 协议 stub），仅为可编译可测；merge 时以 integration 为准统一。

Blocked by: (none)
