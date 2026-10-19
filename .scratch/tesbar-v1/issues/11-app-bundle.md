Status: resolved
Type: task

# 11 — 打包与常驻：App bundle（LSUIElement）+ 登录自启 + README

## Summary

可分发/可日常使用的最终形态：.app bundle（LSUIElement 无 Dock 图标、菜单栏常驻）、SMAppService 登录自启、构建脚本与 README。spec user stories 36/37、ADR-0002。

## Target

- `Scripts/build-app.sh`：`swift build -c Release` → 组装 `TesBar.app/Contents/{MacOS,Resources}`，Info.plist 含 `LSUIElement=true`、bundle id `com.tesbar.app`。
- App 内自启开关接 SMAppService（09 的设置项接线）。
- `README.md`：构建、首次设置（生成 Tesla 开发者凭据、注册 Virtual Key 步骤链接）、使用。
- 全套 `swift test` 通过。

## Acceptance

- `Scripts/build-app.sh` 产出 TesBar.app，Info.plist 校验 LSUIElement。

## Comments

- `Scripts/build-app.sh`（release 构建 → Info.plist → 拷贝二进制 → ad-hoc 签名 best-effort → 打印路径）、`README.md`（构建/CLT 插件参数/首次设置/Virtual Key 配对/自启/限制）。SMAppService 自启开关已在 09 的 SettingsView 落地（`Sources/TesBar/SettingsView.swift`），本票未改动。
- 验证：`./Scripts/build-app.sh` 端到端成功，`plutil` 确认 `LSUIElement=true`、`CFBundleIdentifier=com.tesbar.app`，`codesign -dv` 确认 ad-hoc 签名；`swift test`（带插件参数）113 tests / 7 suites 全绿。
- 备注：实现由 orchestrator 完成（原 implementer 子代理因模型供应商 400 中断，脚本已写好未验证；本次补跑验证并提交）。`build/` 加入 .gitignore。
- `swift test` 全绿。

## Blocked by: 09
