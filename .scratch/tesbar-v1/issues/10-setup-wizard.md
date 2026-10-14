Status: ready-for-human
Type: task

# 10 — 首启向导：OAuth 登录 + Virtual Key 配对引导

## Summary

首启流程串联：填凭据 → OAuth 登录 → 拉车辆列表选默认车 → VCP 公钥生成/展示 → 指引去注册 Virtual Key → 完成进入主界面。spec user stories 1–5。

## Target

- `Sources/TesBar/SetupWizard.swift`：向导视图（SwiftUI），状态机驱动（凭据→登录→选车→密钥→完成）。
- OAuth 经 04 的 AuthService；选车写 VehicleStore.selectedVehicleID；公钥展示/复制经 03。
- 已登录则跳过；token 失效引导重登入口（user story 34）。

## Acceptance

- 状态机逻辑测试：各步骤推进/回退；已登录跳到选车；未配对虚拟钥匙可重看公钥。
- 编译通过（GUI 部分编译即验收，无 GUI CI）。

## Comments

- Commit `5af59b6` (branch `ticket/10`; pre-merge)。
- Files: `Sources/TesBar/SetupWizard.swift`（新增：`SetupStep` + `SetupStepFlow` 纯状态机、`SetupWizard` @Observable presenter、`SetupWizardView` 薄视图），`Tests/TesBarTests/SetupWizardTests.swift`（新增 15 tests）。
- Evidence: `Test run with 15 tests in 0 suites passed`（--filter 本套件）；全仓 `Test run with 102 tests in 6 suites passed`（swift build/test --jobs 1；TestingMacros 竞态多次复现，clean retry 后通过，非代码问题）。
- Tests: 步进 next/back/首步不可回退/done 停住；已登录（Keychain refresh token）恢复到 keyPair 步；凭据空值拒绝不前进；clientID→UserDefaults + secret→Keychain 持久化与 restore 回填（含域名）；配对 URL（trim/percent-encoding/空与空白→nil）；完成标记 verify 前不置、complete() 仅 verify 步生效、连续 skip 到 done 置位；verify 列出车辆/失败不置完成；keyPair 步公钥 PEM 暴露 + 域名持久化；reauthRequired/refreshTokenInvalid → 重登指引文案（user story 34）。
- Deviations: 登录步调 `AuthService.authorize()`（ASWebAuthenticationSession，04 已注为不单测）；QR 标 optional 未做——`pairingURL` 已返回 `URL`，加 QR 码视图属 09 设置面板的展示层决定，接入时一行 `Image(nsService:)` 即可。向导步骤顺序与 ticket Summary（选车在密钥前）不同：按本 ticket 文字步骤 (3) 密钥 → (4) 验证（listVehicles 展示数量/名称即 user story 5 的列表呈现），选默认车动作由 06 的 `VehicleStore.selectVehicle` 在主界面完成，避免双处选车状态。

## Blocked by: 03, 04, 06, 09
