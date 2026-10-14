Status: ready-for-agent

# TesBar v1：macOS 菜单栏 Tesla 车辆状态与控制

## Problem Statement

车主想在 Mac 上一眼看到车辆状态（电量、续航、充电进度、门窗/锁状态），并顺手执行远程控制（空调、解锁、找车等）。现状只有手机 App 一个通道：看一眼状态要掏手机解锁，预热/找车等操作同样被锁在手机里；工作场景中 Mac 常开，这个摩擦每天都发生多次。

## Solution

TesBar：一个原生 macOS 菜单栏应用（无 Dock 图标、登录自启）。菜单栏显示 TesBar 图标；点开菜单即取一次最新车辆数据并展示选中车辆的状态摘要，下方是分组指令入口。数据走 Fleet API 轮询（打开菜单即拉、充电中每分钟、平时每 15 分钟且仅车辆在线时），指令走 VCP 签名直发。单账号多车，菜单内切换车辆。

## User Stories

### 首次设置

1. As a 车主, I want 通过 OAuth 在 Tesla 账户登录一次, so that 之后常驻使用不再重复登录
2. As a 车主, I want 客户端 ID/密钥由我在设置里填入, so that 用我自己的开发者凭据接入 Fleet API
3. As a 车主, I want 应用自动生成 VCP 密钥对并把私钥存入 Keychain, so that 私钥不落明文文件
4. As a 车主, I want 按引导完成 Virtual Key 与车辆的配对, so that 车辆接受我发的签名 Command
5. As a 车主, I want 首次启动时看到车辆列表并选中默认车辆, so that 打开菜单就有默认上下文

### 状态展示

6. As a 车主, I want 菜单栏常驻 TesBar 图标, so that 不占 Dock、随时可点
7. As a 车主, I want 点开菜单即拉取一次最新数据, so that 看到的不是陈旧缓存
8. As a 车主, I want 在菜单里看到电量百分比、续航估算和充电状态, so that 不掏手机就知道车能不能开、要不要充
9. As a 车主, I want 充电中每分钟自动刷新, so that 充电进度实时可信
10. As a 车主, I want 平时每 15 分钟自动刷新且仅在车辆在线时拉取, so that 不把车反复唤醒、不产生多余计费
11. As a 车主, I want 看到车内/车外温度, so that 决定要不要提前开空调
12. As a 车主, I want 看到门窗/锁/后备箱的开闭状态, so that 离开车后能确认有没有关好
13. As a 车主, I want 看到里程数和车辆在线/睡眠状态, so that 了解车辆基本情况
14. As a 车主, I want 数据旁标注“多久前更新”, so that 知道数据新鲜度
15. As a 车主, I want 车辆离线时菜单明确显示离线而不是报错, so that 不误以为应用坏了

### 多车

16. As a 多车车主, I want 菜单内切换当前车辆, so that 两辆车都能看和控
17. As a 多车车主, I want 记住我选中的车辆作为默认, so that 重启应用后不用重选

### 指令（非危险，直发）

18. As a 车主, I want 一键开/关空调并设定温度, so that 上车前把车内温度调好
19. As a 车主, I want 一键开关除霜, so that 冬天出发前除霜除雾
20. As a 车主, I want 鸣笛/闪灯找车, so that 停车场里快速定位车辆
21. As a 车主, I want 开关哨兵模式, so that 离车后按需布防
22. As a 车主, I want 开关充电口和启停充电, so that 插枪后远程开始或按需停止
23. As a 车主, I want 调整充电限值和座椅加热, so that 按当日行程配置充电与保暖

### 指令（危险，长按确认 + 可选门禁）

24. As a 车主, I want 解锁/锁车时长按 1 秒确认, so that 一次误点不会真的解锁
25. As a 车主, I want 开关车门/前后备箱同样长按确认, so that 行李箱不会被误开
26. As a 车主, I want 远程启动前长按确认, so that 车辆不会被误启动
27. As a 车主, I want 可选开启 Touch ID/PIN 门禁（默认关）, so that 他人碰我 Mac 时发不了危险指令

### 指令执行反馈

28. As a 车主, I want 发送后菜单内显示状态行（发送中→成功/失败+原因+重试）, so that 知道指令到底成没成
29. As a 车主, I want 失败时收到 macOS 通知（含原因）, so that 菜单已关也不错过失败
30. As a 车主, I want 成功静默不弹通知, so that 不被成功提示骚扰
31. As a 车主, I want 车辆睡眠时先自动 Wake 再发指令, so that 不用手动两步操作
32. As a 车主, I want 虚拟钥匙未配对时得到明确指引, so that 知道去配对而不是反复重试

### 账户与凭证

33. As a 车主, I want access token 自动续期（401 触发+启动检查）, so that 平时无感
34. As a 车主, I want refresh token 失效时收到通知并引导重新 OAuth, so that 掉线时知道怎么办
35. As a 车主, I want token/私钥都存 Keychain, so that 凭证安全

### 常驻与设置

36. As a 车主, I want 应用为 LSUIElement（无 Dock 图标）且可登录自启, so that 开机即在、不碍事
37. As a 车主, I want 设置里开关自启动、门禁、温度单位, so that 按习惯定制

## Implementation Decisions

- **技术栈**：Swift + SwiftUI `MenuBarExtra`（macOS 13+），LSUIElement，登录自启用 SMAppService（ADR-0002）。
- **数据通道**：全部实时数据走 Fleet API 轮询 `vehicle_data`；Command 走 VCP 签名直发；不部署 Fleet Telemetry 接收端（ADR-0001）。
- **轮询节奏**（已敲定，ADR-0001）：打开菜单即拉一次；充电中每 1 分钟；平时每 15 分钟且仅车辆在线时拉；不主动唤醒睡眠车辆做数据刷新；发指令前的 Wake 除外。
- **单账号多车**：数据模型按 Vehicle 数组建，菜单内车辆切换器，持久化选中车辆为默认。多账号（多套 token/私钥）明确不做。
- **Dangerous Command 门禁**（ADR-0003）：解锁、开闭车门/前后备箱、远程启动须长按 1 秒确认；设置内可选 Touch ID/PIN 门禁（LocalAuthentication），默认关闭；其余指令直发。
- **指令反馈**：菜单内状态行（发送中→成功/失败+原因+重试入口）；仅失败弹 macOS 用户通知，成功静默。
- **认证**：OAuth 拿 token；access token 8 小时过期，启动检查 + 401 触发自动用 refresh token 续期；refresh token 失效才弹通知引导完整重登。refresh token 与 VCP 私钥均存 Keychain。
- **模块划分**：TeslaClient（Fleet API 数据+指令+认证的门面）、VehicleStore（车辆状态与轮询编排，@Observable）、CommandExecutor（Wake→签名→发令→状态行/通知）、KeychainStore（凭证）、菜单 UI（MenuBarExtra 内容）。
- **测试接缝（唯一）**：`TeslaClient` 协议——车辆列表、数据拉取、Wake、签名 Command、token 刷新全走它；生产实现真 HTTP+VCP 签名，测试注入脚本化假实现。轮询节奏用注入时钟驱动；VCP 签名为纯函数，直接测签名/验证往返。

## Testing Decisions

- 好测试只测外部行为：给定 TeslaClient 假实现的脚本（返回什么数据、第几次调用失败等），断言可观察结果——菜单呈现的状态、轮询发生与否与时机、Command 是否在 Wake 之后发出、状态行/通知的触发。不 mock 内部类型，不断言实现细节。
- **被测模块**：VehicleStore（轮询节奏状态机：菜单打开即拉、充电 1 分钟、平时 15 分钟仅在线、睡眠不唤醒）、CommandExecutor（先 Wake 后发令、失败原因映射、成功静默/失败通知）、token 刷新（401 触发续期、refresh 失效引导重登）、VCP 签名纯函数（签名→验证往返、篡改即失败）。
- **测试基建**：脚本化 FakeTeslaClient + 注入时钟，全部在单一 TeslaClient 接缝之后。
- **先例**：绿地项目，无既有测试；本 spec 的接缝即项目首个测试约定。

## Out of Scope

- Fleet Telemetry 推流及其接收端（ADR-0001 否决）
- 多账号（多套 token/私钥）
- 充电完成通知等主动推送类提醒（可作后续迭代）
- 车辆位置地图、行程/充电历史报表
- Watch/iPhone/iPad 端
- 中国区 fleet-api.prd.cn.vn.cloud.tesla.cn 的分区适配（凭据为单区）
- 自动化调度（定时预热、离家模式等场景编排）

## Further Notes

- 凭据（client id/secret）用户已有（盘问 Q1=D），地区为单区；后续多区再议。
- 计费背景：个人开发者每月 $10 折扣，本节奏估算在折扣内；避免高频 Wake 是设计红线（ADR-0001 Consequences）。
- 老款车（2021 前）部分指令可 token 直发、无需签名，但本项目统一按 VCP 签名通道实现，不做双路径。
- 术语表见 `GLOSSARY.md`（TesBar、Fleet API、Command、VCP、Virtual Key、Wake、Dangerous Command）。
