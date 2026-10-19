# TesBar

macOS 菜单栏应用：查看 Tesla 车辆状态、发送控制指令。原生 SwiftUI `MenuBarExtra`（无 Dock 图标，`LSUIElement`），数据走 Fleet API 轮询、指令走 VCP（Vehicle Command Protocol）签名直发。单账号多车，菜单内切换。

## 环境要求

- macOS 13+
- Swift 6.0 工具链（Xcode Command Line Tools 即可，无需完整 Xcode）

## 构建

凭据/私钥打包时注入（ADR-0005），仓库不含真值 `BuildConfig.swift`：

```bash
./Scripts/build-app.sh \
  --client-id xxx \
  --client-secret xxx \
  --private-key path/to/private.pem
```

参数（`--help` 看全部）：

- `--client-id` / `--client-secret`：[developer.tesla.cn](https://developer.tesla.cn) 应用的 OAuth client 凭据。
- `--private-key`：共享 VCP 私钥 PEM **文件路径**。省略时打包后菜单会提示“此构建缺少内置凭据”。
- `--pairing-domain`：公钥托管域名，默认 `public.stanzhai.site`。

也支持同名环境变量（参数优先）：`TESBAR_CLIENT_ID` / `TESBAR_CLIENT_SECRET` / `TESBAR_VCP_PRIVATE_KEY_PEM`（PEM 文本）/ `TESBAR_PAIRING_DOMAIN`。

脚本会比对内置私钥推导公钥与线上 `.well-known` 托管公钥，不一致打警告。产出 `build/TesBar.app`（`LSUIElement=true`、本地固定身份签名），`open build/TesBar.app` 运行。

### CLT 特殊编译参数

CommandLineTools 环境缺少 `libSwiftUIMacros.dylib`（SwiftUI 宏插件运行时，随完整 Xcode 分发），`swift build` / `swift test` 需额外传 `external-plugin-path` 指向该 dylib 副本及插件服务器。`build-app.sh` 已内置；单独跑 `swift test` 见[测试](#测试)。

## 首次设置（两步向导）

1. **登录**：OAuth 授权一次（auth.tesla.cn，中国区账号），token 存 Keychain 自动刷新。
2. **配对**：打开 `https://tesla.cn/_ak/<pairing-domain>`，在车上（或 Tesla App）完成 Virtual Key 注册，点“验证”拉车辆列表确认。

凭据与密钥已内置，用户无需粘贴任何 client_id/公钥。退出登录（设置 → 账户）只删 token 与车辆数据，配对保留，重登即恢复。

### 仅中国区

硬编码 `auth.tesla.cn` / `fleet-api.prd.cn.vn.cloud.tesla.cn`，不支持海外区账号（RegionResolver 固定 CN 域）。海外账号需自行改源码。

## 登录自启

设置 → “登录时启动”。注册走 `SMAppService`（macOS 13+ 官方 API，无需额外 LaunchAgent）。开关即时生效；移动或重命名 `.app` 需重新打开一次开关。

## 限制

- **单账号**：只支持一套 Tesla 凭据 + 一把共享 VCP 私钥（ADR-0005），多账号明确不做（多车在同账号内切换）。
- 无 Dock 图标：设计如此（菜单栏常驻）。

## 测试

```bash
swift test --jobs 1 \
  -Xswiftc -Xfrontend -Xswiftc -external-plugin-path \
  -Xswiftc -Xfrontend -Xswiftc "/tmp/tesbar-plugins#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"

`BuildConfig.swift` 在 gitignore 里：fresh clone 后先跑一次 `./Scripts/build-app.sh`（不带环境变量也行，生成空值兜底），或手工放置同形状文件，再 `swift test`。

偶发 TestingMacros 插件竞态（`external macro implementation type ... not found`）：等几秒重跑即可。
