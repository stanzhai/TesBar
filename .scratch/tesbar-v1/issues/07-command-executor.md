Status: ready-for-human
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

## Comments

- 4ae3c5a `07-command-executor: wake→sign→send orchestration, status line, failure notifications, virtual-key-paired guidance`
  - `Sources/TesBar/CommandExecutor.swift`：`CommandExecutor`（@MainActor ObservableObject，`@Published status`）；`Notifier` 微协议；`CommandStatus`（idle/sending/succeeded/failed(reason, retryable)）。
  - `Sources/TesBar/UserNotificationsNotifier.swift`：生产 `UserNotificationsNotifier`（actor，首发展示授权请求，失败仍投递）。
  - `Sources/TesBar/TeslaClient.swift`：新增 `VirtualKeyNotPairedError`（typed error，05 抛 UNKNOWN_KEY_ID 时映射为它）。
  - `Tests/TesBarTests/CommandExecutorTests.swift` + `Tests/TesBarTests/ScriptedTeslaClient.swift`：全部 6 条验收（sleep→wake→send 顺序、醒车直发不 wake、未配对→配对指引+通知、成功静默、retry 重发、wake 轮询 3×2s 超时）+ 拉不到数据回退 wake。注入 sleep 闭包，测试 0.08s 跑完。
- 3c06994 merge `integration/tesbar-v1`（带入 06 VehicleStore）：对端测试文件同有 `FakeTeslaClient`，本工单的重命名为 `ScriptedTeslaClient` 并将对端标记 `private`，消除重定义。
- 测试证据：`swift test --jobs 1` → `Test run with 19 tests in 2 suites passed`（含本工单 6 项全绿）。
- 偏差：无。测试基建命中 CLT TestingMacros 插件竞态，按仓库说明重试后即绿，非代码问题。

Status: ready-for-human
