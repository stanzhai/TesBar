# 16 — 解锁指令 Fleet API 400：VCSEC unlock 编码为空 payload

Status: ready-for-human

## 现象

真机点"解锁"（确认弹窗后）→ 状态行报"Fleet API 返回 HTTP 400"。锁车正常。统一日志
（subsystem `com.tesbar.app`）确认：两次 POST → 400（12:24:05 / 12:24:13，PID 45364），
均为 HTTP 层拒绝——车端 fault 路径（`process(reply:)`）未走到。

## 根因

`RKE_ACTION_UNLOCK = 0`。protobuf varint 0 是 proto3 默认值，编码器按 proto3 规则跳过该
字段 → `VCSEC.UnsignedMessage` 序列化为**空消息** → Fleet API 校验拒绝（400），指令根本
没到车。

但 `vcsec.proto` 是 **proto2**（`optional RKEAction_E RKE_action = 2`，显式 presence）：
已 set 的字段即使值为 0 也要序列化。Go 参考实现（tesla vehicle-command）encode unlock
的 payload 是 `10 00`（field 2 varint 0）。lock = 1（`10 01`）非默认值所以一直正常。

ticket 12 line 43 把这个 proto3 跳过当成了正确行为并写进了测试注释——当时用假车
（VehicleSim）验证，假车不校验空 payload，真实 API 才拒绝。

## 修复

- `Sources/TesBar/VCP/Protobuf.swift` `encodeVCSECUnsignedMessage`：删掉
  `rkeAction.rawValue != 0` 守卫，`if let rkeAction { writeField(2, rkeAction.rawValue) }`——
  显式设了就写，与 proto2 presence 语义一致。
- 测试期望同步反转：
  - `VCPCoreTests.vcsecEncodings`：unlock `isEmpty` → `== hex("1000")`。
  - `FleetTeslaClientTests.unlockMapsToVCSECUnlock`：payload isEmpty →
    `singleVarint(field: 2) == 0`。

不动 lock/remoteDrive/trunk 路径（非 0 值，编码不变）；`RoutableMessage`/CarServer 字段
全是非 0 值或 bytes，不受 presence 影响。

## 验证

- 定向 3 测试（vcsecEncodings / unlock / lock）过；全量 116 测试过。
- 重新打包运行（PID 47624）。待用户真机点解锁确认 400 消失、车门解锁。

## Comments

- 日志 `Logger.error("Fleet API …")` 里 URL/状态/体全部 `<private>`（未标
  `privacy: .public`），事后无法从统一日志取 400 响应体。本次靠 ticket 12 记录定位，
  未改日志 privacy（避免把 VIN/URL 打进系统日志）。
