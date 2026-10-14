# 0002 SwiftUI MenuBarExtra 原生实现

需要本地生成/保存 VCP 私钥并为 Command 签名，私钥放 macOS Keychain 最顺理成章；Electron/Tauri 会把"签名密钥放哪"变成安全难题。决定：Swift + SwiftUI `MenuBarExtra`（macOS 13+），`LSUIElement` 无 Dock 图标常驻，登录自启用 SMAppService。
