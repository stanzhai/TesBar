Status: ready-for-agent
Type: task

# 09 — 菜单 UI：MenuBarExtra 状态面板 + 车辆切换 + 指令入口 + 危险指令长按门禁

## Summary

SwiftUI `MenuBarExtra` 菜单：状态摘要（电量/续航/充电、内外温、门窗/锁/后备箱、里程、在线/睡眠、"多久前更新"）、车辆切换、分组指令、危险指令长按 1 秒确认、可选 Touch ID/PIN 门禁、设置区（自启/门禁/温度单位/凭据）、状态行。spec user stories 5–14、16、17、18–26、36、37；ADR-0002/0003。

## Target

- `Sources/TesBar/App.swift`：`@main`，MenuBarExtra，LSUIElement（Info.plist / bundle 设置）。
- 状态面板绑定 06 的 VehicleStore；指令按钮调 07 的 CommandExecutor。
- 危险指令：长按 1s 确认手势/按钮；门禁开时叠加 LocalAuthentication（Touch ID/PIN，`.deviceOwnerAuthentication`），默认关。
- 指令清单按 spec：空调开/关+温度、除霜、鸣笛/闪灯、哨兵、充电口/启停充电、充电限值、座椅加热（直发）；解锁/锁车、车门/前后备箱、远程启动（长按+门禁）。
- 车辆切换器（多车）；未选车时首启流程入口（拉列表、选默认车）。
- 设置：自启（SMAppService）、门禁开关、温度单位 °C/°F、client id/secret 输入。
- 数据旁"多久前更新"；离线显示离线不报错。
- VCP 未配对时指引入口（生成公钥 PEM 展示/复制，配合 03 的公钥导出；完整配对引导 = 注册 Virtual Key 后说明下一步）。

## Acceptance

- `swift build` 通过；app 可启动出现菜单栏图标（CI 无 GUI 时以编译+VM 逻辑测试为准，长按/门禁逻辑抽为可测纯函数或 ViewModel）。
- 长按确认逻辑测试：<1s 松手不触发指令；≥1s 触发一次。
- 门禁逻辑测试：开启时未经 LocalAuthentication 成功不调 executor（用假 gate 对象注入）。

## Blocked by: 05, 06, 07
