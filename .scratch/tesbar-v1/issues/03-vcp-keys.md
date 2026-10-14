Status: ready-for-agent
Type: task

# 03 — VCP 私钥对生成 + 签名纯函数（SecKey ECDSA P-256）

## Summary

用 Security 框架生成 VCP 密钥对、私钥入 Keychain（经 02 的 KeychainStore）、公钥导出 PEM 供 Virtual Key 注册；`sign(command:)` 纯函数用 SHA256+ECDSA-P256 签名。spec user stories 3/4、Testing Decisions 的"签名纯函数直接测往返"。

## Target

- `Sources/TesBar/VCPKeyManager.swift`：
  - `generateKeyPair()`：SecKeyCreateRandomKey（ECDSA P-256），私钥 PEM 导出给 KeychainStore 存，公钥导出 PEM（`BEGIN PUBLIC KEY`）返回给调用方（供配对流程展示）。
  - `sign(_ message: Data) throws -> Data`：SHA256 摘要 + ECDSA 签名（derRepresentation），加载 Keychain 私钥。
- VCP 规范签名的 message 组装（domain + command + time 等）在 04/07 的 Fleet API 客户端处，本 ticket 只交付原始签名能力与往返。

## Acceptance

- 测试：生成→公钥 PEM 格式正确（base64 结构可解析）；签名→用公钥 SecKeyVerifySignature 验证通过；篡改 message 验证失败。

## Blocked by: 02
