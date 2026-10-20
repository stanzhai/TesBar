# 17 — 发令后状态及时更新 + 地址行 pointer 光标

Status: ready-for-human

## 需求

1. 锁车/解锁后，状态卡与右上角"已锁车/未锁车"徽标不更新——需要及时跟上。
2. 地图卡下方地址行可点击，鼠标悬浮应显示手型（pointer）光标。

## 根因

- `send()` 成功后其实已经在 `refreshAfterCommand()`，但 Tesla 后端 `vehicle_data`
  有几秒滞后：指令已被车执行、后端数据还是旧值，一次拉新拿到的仍是旧快照
  （`doors.locked` 未翻转），UI 不动。
- 地址行是 `.buttonStyle(.plain)` 的 Button：macOS SwiftUI 不给 plain button 换光标。

## 实现

- `VehicleStore`：
  - `refreshAfterCommand(expected:)`：立即拉一次后，最多再收敛轮询 4 次（间隔 2s），
    指令对应的可观测字段（locked/hvacOn/sentryOn/charge.state/trunk 开关）翻转即停。
  - `pollAfterCommand(expected:baseline:)`：单轮收敛步骤（拉新 + 与基线比较），可单测。
  - `changed(command:before:after:)`：指令 → 字段翻转判定；喇叭/闪灯等无快照可观测的
    指令返回 true（不轮询）。
- `CommandCards.send()`：成功后改调 `refreshAfterCommand(expected: command)`
  （解锁卡与 3 个开关卡共用此路径，全部受益）。
- 地址行：`.onHover { NSCursor.pointingHand.push()/pop() }`。

## 验证

- 新测试 `refreshAfterCommandPollsUntilLockFlips`：立即刷新仍旧值 → 注入翻转快照 →
  收敛轮询拉到 flipped 且返回 true。
- 顺手修 `pressAtOrPastOneSecondFiresOnce` 的真实时间竞态（两个 `Date()` 之间机器变慢
  导致 1.0s 恰差 ~2µs：tick 用 1.1s，不再贴边）。
- 117 测试全绿；打包运行中（PID 65785）。真机待验：锁/解锁后徽标与卡片 ≤8s 内更新。

## Comments

- swift test 在本机 CLT 有已知 runner 抖动（helper 挂起/SIGTRAP，ticket 12 记录过
  rm -rf .build 修法）；本次另发现 `Task {}` + ManualClock 编排的测试会把 runner
  卡死，收敛轮询改为可单步调用的 `pollAfterCommand` 后规避。
