# 五项体验优化：地图导航 / 移除门禁设置 / 解锁弹窗 / 成功提示自动消失 / 睡眠报错降噪

Status: ready-for-human

## 需求与实现

1. **地图卡**：zoom span 0.01 → 0.005（放大一级）；地址行改为 Button，点击打开
   `https://maps.apple.com/maps?daddr=<lat>,<lon>&dirflg=d`（saddr 缺省 = 从当前位置出发，系统默认地图 app 承接导航）。
2. **设置面板**：删除"危险指令门禁"整节（Touch ID 开关 + 说明）。`AppSettings.biometricGateEnabled`/
   `gateKey` 一并删除（无其他引用）；组合根 `gateEnabled: { false }`，长按/弹窗确认路径保留但门禁恒关。
3. **解锁卡**：`DangerCard`（长按）→ `UnlockCard`（tap + confirmationDialog）：已锁 → 弹"解锁车辆？"确认
   （destructive 按钮）；未锁/未知 → 直接发 lock（非危险指令）。
4. **成功提示 5s 自动消失**：`CommandExecutor.scheduleSuccessAutoClear()`（execute/retry 共用），仅
   succeeded 清回 idle；failed 保留等用户处理。
5. **睡眠车取数报错忽略**：StatusCard 报错行加 `listState != asleep/offline` 条件——旧数据角标
   （"数据为 X 前"）已提示，408/超时为预期行为不再刷红。

## 验证

- 116 测试全绿。打包运行中；面板交互（地图点击、解锁弹窗）待用户手点。

## Comments

- unlock 仍是 `VehicleCommand.isDangerous == true`（枚举语义未动）；ADR-0003 的长按门禁 UI 已被
  用户 2026-10 精简为弹窗确认，coordinator 仍在组合根但 UI 不再使用。
- `confirmationDialog` 在 MenuBarExtra 面板上的表现待真机确认（issue 13 只证实 `.sheet` 会打死面板；
  若 dialog 也有问题需退回独立窗口方案）。
