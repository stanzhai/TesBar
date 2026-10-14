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
配对到车辆上的公钥，对应 TesBar 本地保存（Keychain）的私钥。

**Wake**:
把休眠车辆唤醒的请求，发送任何 Command 或取实时数据前可能需要。计费独立于普通请求。
_Avoid_: 唤醒、wake-up

**Dangerous Command**:
须长按确认（可选 Touch ID/PIN 门禁）的 Command：解锁、开闭车门/前后备箱、远程启动。
_Avoid_: 高危指令
