Status: ready-for-agent
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
- `swift test` 全绿。

## Blocked by: 09
