# 0004 默认不激活车辆：list state 驱动取数

用户主诉求是“取数不唤醒车”。Fleet API 的 `vehicles` list 本身不惊扰车辆（返回缓存态 `state: online/asleep/offline`），而 `vehicle_data` 对睡眠车会超时并强制唤醒、打断省电。决定：所有取数路径（menuOpened/refreshNow/轮询/selectVehicle）先看 list `state`，非 `online` 不发 `vehicle_data`，UI 显示降级卡 + 显式“唤醒”按钮（`wakeNow`：`wake` 后强制拉一次）。旧数据/测试默认无 `state` 时保守视为在线，保持旧行为。

## Considered Options

- 每次直接 `vehicle_data`（旧行为）：实现最省，但睡眠车每次取数都 408 + 唤醒，违背主诉求，放弃。
- Fleet Telemetry 推流（ADR-0001 已否）：形态不匹配。

## Consequences

- 睡眠车打开菜单只看到降级卡（名称 + 睡眠图标 + 唤醒按钮），拿不到电量/温度；点“唤醒”才恢复完整卡片。
- 轮询循环对非在线车直接跳过，不唤醒（ADR-0001 节奏不变，只是入口多了 list state 门）。
- 发指令不受此门限制：CommandExecutor.ensureAwake 仍自动唤醒后发令（ADR-0001 不变）——危险指令长按 1s 期间车已被唤醒属预期。
- `state` 用 String 宽容解码（API 可能返回 "processing" 等），UI 只特判 asleep/offline。
