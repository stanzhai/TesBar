Status: ready-for-agent
Type: task

# 12 — VCP 核心：protobuf 编码 + ECDH 会话 + HMAC 认证（纯 Swift）

## Summary

原生 VCP（Vehicle Command Protocol）核心，纯函数、无 HTTP：RoutableMessage/VCSEC/CarServer protobuf 手写编码器、P-256 ECDH 会话密钥、TLV metadata + HMAC-SHA256 认证。研究依据：`/Users/stan/Projects/tesbar-research/vcp-fleet-api.md`（含官方协议测试向量来源）。这是 05 发送签名指令的地基。

## Target

- `Sources/TesBar/VCP/` 下：
  - `ProtobufWriter/Reader`：varint、tag-delimited、bytes/string/uint32/enum 字段的最小编码器（够用即可，非通用库）。
  - `RoutableMessage` 编码：`to_destination`(domain enum: VCSEC=2, Infotainment=3)、`from_destination`(随机 16B routing_address)、`protobuf_message_as_bytes`、`signature_data`、`uuid`(≤16B 随机)、`flags=2`（FLAG_ENCRYPT_RESPONSE）。字段号：to=6, from=7, payload=10, sub_sigData=13, request_uuid=50, uuid=51, flags=52。
  - `VCSEC.UnsignedMessage`：`RKEAction_E`（LOCK/UNLOCK/REMOTE_DRIVE/WAKE）、`ClosureMoveRequest`(front/rear)。
  - `CarServer.Action`（本项目指令集所需子集）：hvacAutoAction powerOn、hvacTemperatureAdjustmentAction、chargingStartStopAction、setChargingAmps、chargePort open/close、sentryMode、honkHorn、flashLights、seat heater/level、preconditioningMax/bioweapon（defrost）、setChargeLimit、remoteStartDrive 归 VCSEC。
  - `SessionCrypto`：ECDH(SecKey) → `K = SHA1(Sx)[0..<16]`；`K' = HMAC-SHA256(K, "authenticated command")`；session info 校验 key `= HMAC-SHA256(K, "session info")`。
  - `AuthMetadata` TLV（tag 升序，0xFF 结尾）：TAG_SIGNATURE_TYPE(0)=8, TAG_DOMAIN(1), TAG_PERSONALIZATION(2)=VIN, TAG_EPOCH(3)=16B, TAG_EXPIRES_AT(4)u32BE, TAG_COUNTER(5)u32BE, TAG_FLAGS(7 仅非零)。
  - `authenticatedCommand(payload:domain:vin:session:) -> Data`：`tag = HMAC-SHA256(K', TLV || 0xFF || P)`，组装 Signatures.SignatureData（signer_identity.public_key=0x04||x||y，HMAC_Personalized_data{epoch, counter, expiresAt, tag}），返回完整 RoutableMessage 字节。
  - `MessageFault` 解码（signedMessageStatus）：至少 UNKNOWN_KEY_ID(3)、INVALID_SIGNATURE(5)、INVALID_TOKEN_OR_COUNTER(6)、INCORRECT_EPOCH(15)、TIME_EXPIRED(17)、REMOTE_ACCESS_DISABLED(21)。

## Acceptance

- 测试（无网络）：
  - protobuf 编码往返（writer→reader）。
  - `authenticatedCommand` 输出可用独立重算的 HMAC 验证（用测试侧重建 K' 复算 tag 相等）。
  - 随机 session/uuid 下输出确定性：同输入除 uuid/routing_address 外字段一致。
  - `MessageFault` 从样例字节解码正确。
- `swift build` 通过；全部测试串行跑（`--jobs 1`，CLT 插件竞态规避）。

## Blocked by: (none)
