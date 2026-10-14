Status: ready-for-agent
Type: task

# 03 — VCP 私钥对生成 + Keychain 集成

## Summary

prime256v1 密钥对生成（SecKeyCreateRandomKey），私钥 PEM 存 Keychain（经 02），公钥导出 PEM 供 `.well-known` 托管与配对展示。注意：VCP 用 ECDH+HMAC，该私钥同时是 12 的会话密钥来源；本 ticket 不做签名。

## Target

- `Sources/TesBar/VCPKeyManager.swift`：
  - `ensureKeyPair() throws -> String`：已有（Keychain 有私钥）则返回公钥 PEM；否则生成 P-256 密钥对，私钥 PEM（PKCS#8 或 SEC1，标注）入 KeychainStore，返回公钥 PEM（`-----BEGIN PUBLIC KEY-----`）。
  - `loadPrivateKey() throws -> SecKey`：从 Keychain PEM 重建 SecKey。
- 幂等：重复调用不重复生成。

## Acceptance

- 测试（真 Keychain，UUID 账户隔离 + 清理）：
  - 首次调用生成、二次调用返回相同公钥 PEM。
  - PEM 可被 `SecKeyCreateWithData` 重建，curve 为 P-256。
- 串行 `swift test --jobs 1` 全绿。

## Blocked by: 02
