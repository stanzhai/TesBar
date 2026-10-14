# TesBar

macOS 菜单栏应用：查看 Tesla 车辆状态、发送控制指令。原生 SwiftUI `MenuBarExtra`（无 Dock 图标，`LSUIElement`），数据走 Fleet API 轮询、指令走 VCP（Vehicle Command Protocol）签名直发。单账号多车，菜单内切换。

## 环境要求

- macOS 13+
- Swift 6.0 工具链（Xcode Command Line Tools 即可，无需完整 Xcode）

## 构建

```bash
./Scripts/build-app.sh
```

产出 `build/TesBar.app`（含 `LSUIElement=true` 的 Info.plist、ad-hoc 签名），双击或 `open build/TesBar.app` 运行。

### CLT 特殊编译参数

CommandLineTools 环境缺少 `libSwiftUIMacros.dylib`（SwiftUI 宏插件的运行时，随完整 Xcode 分发），SwiftPM 编译 `MenuBarExtra` 相关代码时会报错找不到插件。因此 `swift build` / `swift test` 需额外传 `external-plugin-path` 指向一个该 dylib 的副本及其插件服务器：

```bash
swift build -c release --jobs 1 \
  -Xswiftc -Xfrontend -Xswiftc -external-plugin-path \
  -Xswiftc -Xfrontend -Xswiftc "/tmp/tesbar-plugins#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"
```

`build-app.sh` 已内置这些参数；单独跑 `swift test` 时需同样携带（见 [Tests](#测试)）。

## 首次设置（应用内向导）

应用首次打开自动进入 SetupWizard：

1. **注册 Tesla 开发者应用**：在 [developer.tesla.com](https://developer.tesla.com) 创建应用，拿到 client_id / client_secret / scopes，填入向导第一步。Tesla 审核通过后你的账户才能调用 Fleet API。
2. **登录**：OAuth 授权一次，token 自动存 Keychain 刷新。
3. **生成并托管公钥**：向导生成 P-256 密钥对（私钥存本机 Keychain）。把展示的公钥（SPKI PEM）托管到你控制的域名 `https://<你的域名>/.well-known/appspecific/com.tesla.vcp/<domain>`（Tesla 按固定路径拉取），填入域名后应用拼出配对链接。
4. **配对 Virtual Key**：打开向导给出的 `https://tesla.com/_ak/<你的域名>` 链接，在车上（或 Tesla App）完成 Virtual Key 注册，之后车辆才接受 TesBar 签名的指令。
5. **验证**：拉取车辆列表确认连通。

之后所有设置都在菜单栏图标 → 设置内调整。

## 登录自启

设置 → “登录时启动”。注册走 `SMAppService`（macOS 13+ 官方 API，无需额外 LaunchAgent）。开关即时生效；移动或重命名 `.app` 需重新打开一次开关。

## 限制

- **单账号**：只支持一套 Tesla 凭据 + 一把 VCP 私钥，多账号明确不做（多车在同账号内切换）。
- 无 Dock 图标：设计如此（菜单栏常驻）。

## 测试

```bash
swift test --jobs 1 \
  -Xswiftc -Xfrontend -Xswiftc -external-plugin-path \
  -Xswiftc -Xfrontend -Xswiftc "/tmp/tesbar-plugins#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"
```

偶发 TestingMacros 插件竞态（`external macro implementation type ... not found`）：等几秒重跑即可。
