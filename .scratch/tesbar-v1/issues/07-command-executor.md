Status: ready-for-agent
Type: task

# 07 — CommandExecutor：Wake→签名→发令→状态行/通知

## Summary

指令执行编排：睡眠车先自动 Wake 再发签名指令；状态行（发送中→成功/失败+原因+重试）；成功静默、失败弹 macOS 通知；虚拟钥匙未配对明确指引。spec user stories 28–32、ADR-0003。

## Target

- `Sources/TesBar/CommandExecutor.swift`，依赖注入 `any TeslaClient`。
- `execute(_ command: VehicleCommand, vehicleID:) async`：
  - Wake 条件：当前 snapshot 为睡眠/离线（或拉不到）→ 先 `wake`，等待短轮询至 online（带上限，超时报失败原因）。
  - 发令走 `signAndSend`；失败映射人类可读原因（网络/401 已处理/未配对虚拟钥匙 `missing_virtual_key` 类错误→专门提示配对）。
- 可观察状态：`lastResult`（发送中/成功/失败+原因）、`retry()`（重发上一条）。
- 通知：注入 `Notifier` 微协议（`send(title:body:)`），生产用 UserNotifications UNUserNotificationCenter；失败才发，成功静默。仅菜单内状态行 + 失败通知，无第三态。
- 危险指令的门禁长按在 UI 层（10），executor 不区分危险。

## Acceptance

- 测试（FakeTeslaClient 脚本）：
  - 车睡眠 → 先 wake（等 online）后 signAndSend。
  - 车醒 → 直接 signAndSend，不 wake。
  - signAndSend 抛未配对 → 状态行含配对指引文案、通知发出。
  - 成功 → 通知不发、状态行=成功。
  - retry 重发同一条指令。
  - wake 等待超时 → 失败原因含超时。

## Blocked by: 01
