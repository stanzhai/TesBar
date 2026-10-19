# TesBar

macOS 菜单栏应用：查看 Tesla 车辆状态并发送控制指令。

## Language

**TesBar**:
本项目，macOS 菜单栏（status bar）应用本体。
_Avoid_: 状态栏应用（泛指时可用，指本项目时用 TesBar）

**Fleet API**:
Tesla 官方 REST API（developer.tesla.com），本项目唯一的数据与指令通道。
_Avoid_: Tesla API、Owner API（旧称）

**Command**:
发送给车辆的写操作（解锁、空调、充电等），经 Fleet API 下发。
_Avoid_: 指令、action

**Vehicle Command Protocol (VCP)**:
Tesla 的指令签名协议：Command 必须由本地私钥签名、且公钥（Virtual Key）已与车辆配对，车辆才会执行。
_Avoid_: 签名协议

**Virtual Key**:
配对到车辆上的公钥。本项目用一把“共享私钥”（ADR-0005）打包内置，公钥托管在配对域名供车辆校验。
_Avoid_: 车辆密钥、keypair

**共享私钥 / Shared Key**:
开发者持有、打包时经环境变量注入 `BuildConfig` 的 VCP 私钥；所有安装实例共用，用户零配置。
_Avoid_: 内置密钥（口语可用，指 ADR-0005 方案时用“共享私钥”）

**配对域名 / Pairing Domain**:
托管共享公钥 `.well-known/appspecific/com.tesla.3p.public-key.pem` 的 HTTPS 域名；配对 URL `tesla.cn/_ak/<domain>`（中国区）由此生成。默认 `public.stanzhai.site`。

**Wake**:
把休眠车辆唤醒的请求，发送任何 Command 或取实时数据前可能需要。计费独立于普通请求。
_Avoid_: 唤醒、wake-up

**Dangerous Command**:
须长按确认（可选 Touch ID/PIN 门禁）的 Command：解锁、开闭车门/前后备箱、远程启动。
_Avoid_: 高危指令

**退出登录 / Sign Out**:
删 access/refresh token、清车辆列表与快照、停轮询；**保留**车辆配对（Virtual Key 不动）。下次登录即恢复，无需重新配对。
_Avoid_: 注销、登出（与“退出 TesBar”区分）

**list state**:
`/vehicles` 列表返回的车辆状态串（`online`/`asleep`/`offline`…）。ADR-0004：非 `online` 不拉 `vehicle_data`。String 宽容解码，UI 只特判 asleep/offline。

**降级卡**:
车辆睡眠/离线时替代完整状态卡的展示：名称 + 睡眠图标 + “唤醒”按钮（`wakeNow`），不显示电量/温度等实时数据。
