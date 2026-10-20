# 设置面板挂 sheet 导致菜单面板僵死（方角、不关闭、不重绘）

Status: resolved

## 现象

- 软件运行一段时间后，菜单栏面板（`MenuBarExtra(.window)`）从系统圆角风格变成矩形，且毛玻璃材质丢失（内容近乎纯黑）。
- 取证（2026-10-20，用户运行中的实例）：面板窗口 340×501，顶行像素横跨全宽（无圆角曲线）；app 失焦后面板不自动关闭、不重绘（两次截屏逐像素相同）；点击穿透失灵 —— 僵尸窗口。向导窗口同时存在。

## 根因

`MenuBarExtra(.window)` 面板 + attached `.sheet` 是 SwiftUI 已知坏组合（Apple 论坛 741553/741601、SO 78835562，macOS 14.6/15+ 未修）。本仓库 cb9307e 已因同一问题把向导从 sheet 挪去独立 `Window`，但 `SettingsView` 仍是面板挂载的 sheet（`MenuContent.swift` 旧 53 行）。sheet 关闭（Escape/按钮）后 popover 管线死掉：面板变僵尸窗口，后续拉起时 popover mask/材质丢失 → 方角。

复现（干净实例，未碰向导）：打开面板 → 点"设置…"（sheet 弹出）→ Escape 关闭 → 面板立即僵尸化（不再响应状态项点击、永不关闭、不重绘）。

## 修复

照搬 cb9307e 模式：设置改为独立 `Window(id: SettingsView.windowID)`，"设置…"按钮走 `NSApp.activate` + `openWindow`，面板不再挂任何 sheet（f2c49a8 之后）。面板内仅存的 `confirmationDialog` 在 SettingsView 内，随窗口走，不落面板。

## Comments

- 2026-10-20 修复落地：`App.swift` 双 Window 场景（设置 + 向导），`MenuContent` 删 sheet 与 `showSettings`。114 测试通过。
