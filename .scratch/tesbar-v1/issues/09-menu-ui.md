Status: resolved
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

## Comments

- **Commits** (branch `ticket/09`): `406a6a2` 09-menu-ui: MenuBarExtra shell + ConfirmGate/门禁/设置逻辑与测试 · `77996b2` merge integration/tesbar-v1 (10 setup wizard) · `24a3b78` 09-menu-ui: 首启入口接通 SetupWizard 向导。
- **Files**: `Sources/TesBar/App.swift` (`@main` MenuBarExtra window 样式, AppServices 组合根, ExecutorInvoker, OfflineTeslaClient), `MenuContent.swift` (StatusCard/CommandGroups/DangerButton), `MenuLogic.swift` (ConfirmGate/BiometricGate+LocalAuthGate/CommandInvoking/DangerousCommandCoordinator/StatusFormatting), `AppSettings.swift` (UserDefaults 设置 + SMAppService 自启), `SettingsView.swift` (设置 sheet + SetupEntry + VCP 公钥展示/复制), 删除 `main.swift`；`TeslaClient.swift` `Door` enum 补 `CaseIterable`；`CommandExecutor.swift` `describe` 增 `AuthError.reauthRequired` → "登录已过期" 引导。
- **Tests**: `Tests/TesBarTests/MenuLogicTests.swift` 11 tests — ConfirmGate <1s 取消/≥1s 触发一次不重复/复位重臂；门禁开 + 认证失败不调 invoker、成功才发；门禁关直发；非危险指令绕过；<1s 松手丢弃并重臂；updatedAgo/°C°F/门锁文案。`swift build --jobs 1` + `swift test --jobs 1` → `Test run with 113 tests in 7 suites passed`（合并 10 的 SetupWizard 之后）。
- **Deviations**:
  - CLT（CommandLineTools）不带 `libSwiftUIMacros.dylib`，SwiftUI `@State` 宏全部编译失败（非 flake）。Xcode 在 `/Applications/Xcode.app` 有同版本 dylib 但 license 未接受（无 sudo）。绕过：拷 dylib 到 `/tmp/tesbar-plugins` 并 `swift build --jobs 1 -Xswiftc "-Xfrontend" "-external-plugin-path" -Xswiftc "-Xfrontend" "/tmp/tesbar-plugins#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"`。正常机器（license 已接受）直接 `swift build --jobs 1` 即可。
  - `@main` 用 `NSApp.setActivationPolicy(.accessory)`（AppDelegate）；Info.plist `LSUIElement` 留给 11 打包。
  - 凭据保存后需重启应用重建 client（设置文案已注明）；ticket 10 的 SetupWizard 已合并并在首启入口打开，后续由 10 串完整流程。
  - 危险指令判定沿用 `VehicleCommand.isDangerous`（unlock/doorOpen/doorClose/remoteStart）；`lock` 不属危险（锁车是安全方向），门禁测试用 `.unlock`。
