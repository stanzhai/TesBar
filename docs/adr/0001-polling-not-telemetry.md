# 0001 轮询取数 + 签名指令，不用 Fleet Telemetry

TesBar 是单用户 macOS 菜单栏应用。Fleet Telemetry 需要 VCP 服务器 + 公网可达的接收端，对桌面端形态是纯负担；官方对个人开发者每月 $10 折扣，菜单栏场景的低频轮询 `vehicle_data` 足以覆盖。决定：全部实时数据走轮询，Command 走 VCP 签名直发，不部署 Telemetry 接收端。

## Considered Options

- Fleet Telemetry 推流：成本最优（Tesla 官方推荐），但要求常驻接收端，放弃。

## Consequences

- 轮询节奏必须保守（分钟级、车醒时才拉），否则计费与车辆休眠都会受损；唤醒前必须先查车辆在线状态。
- 已敲定的节奏：打开菜单即拉一次；充电中每 1 分钟；平时每 15 分钟且仅在车辆在线时拉，不主动唤醒睡眠车辆。
