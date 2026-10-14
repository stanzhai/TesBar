Status: ready-for-human
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

## Comments

- Commit df35ebd（branch `ticket/03`，已 merge integration/tesbar-v1）。
- Files: `Sources/TesBar/VCPKeyManager.swift`（新增），`Sources/TesBar/KeychainStore.swift`（init 注入 service/privateKeyAccount，默认值不变，仅为测试隔离），`Tests/TesBarTests/VCPKeyManagerTests.swift`（新增 8 tests）。
- Evidence（merge 后全仓）: `Test run with 27 tests in 3 suites passed after 0.193 seconds`（swift build/test --jobs 1；期间遇 TestingMacros 加载竞态，按惯例 rm -rf .build 重试通过）。
- 关键平台事实（macOS 27 CLT 实测）：`SecKeyCopyExternalRepresentation` 私钥=raw ANSI X9.63（**point65||scalar32**，点在前），公钥=raw 65B 点（**非** SPKI DER）；`SecKeyCreateWithData` 只接受 raw 输入，对合法 SEC1/PKCS#8/SPKI DER（含 openssl 生成）一律 -50 paramErr。故实现自行做 DER 包装/解包：私钥存 SEC1（RFC 5915）PEM，公钥输出 SPKI PEM，重建时解包回 raw 交给 SecKeyCreateWithData。openssl 交叉验证：`openssl ec -pubout` 由私钥 PEM 派生的公钥 PEM 与本实现输出字节一致。
- Deviations: ticket 原文推测"公钥 ExternalRepresentation 已是 SPKI DER"——本机不成立（实测 65B raw 点），已按实际行为自行包装；私钥格式选 SEC1（ticket 允许 SEC1 或 PKCS#8，文件头 `EC PRIVATE KEY` 标注）。

## Blocked by: 02
