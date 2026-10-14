Status: ready-for-agent
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

## Blocked by: (none)
