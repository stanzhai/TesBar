Status: ready-for-agent
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

## Blocked by: 03, 04, 06, 09
