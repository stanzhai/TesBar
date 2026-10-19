# 0005 共享内置 VCP 私钥（打包注入，不再按设备生成）

原实现每台设备在 Keychain 里生成一把 P-256 私钥，用户需为每台设备各自走一遍 tesla.cn/_ak 配对。对单用户多设备（Mac + 备用机）这是重复劳动，且换机即全部重配。决定：开发者持有一把“共享私钥”，`build-app.sh` 打包时经 `TESBAR_VCP_PRIVATE_KEY_PEM` 注入 `BuildConfig`；公钥由托管域名（默认 `public.stanzhai.site`）的 `.well-known/appspecific/com.tesla.3p.public-key.pem` 提供；所有设备共用同一配对身份。客户端凭据（client_id/secret）同理注入（`TESBAR_CLIENT_ID/SECRET`），用户首次设置只剩“登录 + 配对”两步。

## Considered Options

- 每设备独立密钥（原方案）：安全性更优（单机泄漏不波及其他设备），但多设备重配对成本高，且 Keychain 生成/存储代码面更大，放弃。
- 运行时从服务器拉私钥：引入常驻服务，与 ADR-0001 的零后端形态冲突，放弃。

## Consequences

- 私钥编进二进制即可被提取：任何拿到 app 的人都能以该身份对已配对车辆发签名指令。**威胁模型**：TesBar 为个人/小圈子分发，app 不公开渠道传播则等价于私钥不外泄；一旦公开分发放弃该方案。
- 无法远程吊销一把泄漏的共享私钥；换钥 = 托管新公钥 + 全部车辆重新走 tesla.cn/_ak 配对（车端会拒绝旧 key 的指令）。
- `VCPKeyManager` 只保留 PEM→SecKey 重建与公钥推导的纯函数；Keychain 不再存私钥（token API 保留）。
- 构建脚本对内置私钥推导的公钥与线上托管公钥做一致性自检，不一致仅警告（车辆会拒绝签名指令）。
- 仓库不含真值 `BuildConfig.swift`（gitignore）；开发构建 `isComplete == false` 时菜单提示用 build-app.sh 重新打包。
