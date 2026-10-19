#!/bin/bash
# TesBar.app 组装脚本（ticket 11，spec user story 36、ADR-0002）。
# 用法：./Scripts/build-app.sh [--client-id X] [--client-secret X]
#                           [--private-key FILE] [--pairing-domain X]
# 未传的项回退到同名环境变量（TESBAR_CLIENT_ID 等）；都没有则编空值——
# app 可跑但菜单提示“构建缺少凭据”。
usage() {
  cat <<'USAGE'
用法: ./Scripts/build-app.sh [选项]

选项:
  --client-id ID          OAuth client ID（回退 TESBAR_CLIENT_ID）
  --client-secret SECRET  OAuth client secret（回退 TESBAR_CLIENT_SECRET）
  --private-key FILE      VCP 私钥 PEM 文件路径（回退 TESBAR_VCP_PRIVATE_KEY_PEM）
  --pairing-domain HOST   公钥托管域名，默认 public.stanzhai.site（回退 TESBAR_PAIRING_DOMAIN）
  -h, --help              显示本帮助
USAGE
}

die() { echo "错误: $*" >&2; usage >&2; exit 2; }

client_id="${TESBAR_CLIENT_ID:-}"
client_secret="${TESBAR_CLIENT_SECRET:-}"
pairing_domain="${TESBAR_PAIRING_DOMAIN:-public.stanzhai.site}"
private_key_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --client-id)          [ $# -ge 2 ] || die "--client-id 缺参数"; client_id="$2"; shift 2 ;;
    --client-secret)      [ $# -ge 2 ] || die "--client-secret 缺参数"; client_secret="$2"; shift 2 ;;
    --private-key)        [ $# -ge 2 ] || die "--private-key 缺参数"; private_key_file="$2"; shift 2 ;;
    --pairing-domain)     [ $# -ge 2 ] || die "--pairing-domain 缺参数"; pairing_domain="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "未知参数: $1" ;;
  esac
done

# 私钥：--private-key 文件优先；否则环境变量 TESBAR_VCP_PRIVATE_KEY_PEM（PEM 文本）。
private_pem="${TESBAR_VCP_PRIVATE_KEY_PEM:-}"
if [ -n "$private_key_file" ]; then
  [ -f "$private_key_file" ] || die "私钥文件不存在: $private_key_file"
  private_pem="$(cat "$private_key_file")"
fi

echo "==> generate Sources/TesBar/BuildConfig.swift"
{
  echo "// 由 build-app.sh 生成（ADR-0004）；不要手改、不要提交。"
  echo "public enum BuildConfig {"
  echo "    public static let clientID = \"$client_id\""
  echo "    public static let clientSecret = \"$client_secret\""
  echo "    public static let pairingDomain = \"$pairing_domain\""
  if [ -n "$private_pem" ]; then
    echo "    public static let vcpPrivateKeyPEM: String? = \"\"\""
    printf '%s\n' "$private_pem" | sed 's/^/    /'
    echo "    \"\"\""
  else
    echo "    public static let vcpPrivateKeyPEM: String? = nil"
  fi
  echo ""
  echo "    /// true = 构建注入了全部必需配置。"
  echo "    public static var isComplete: Bool {"
  echo "        !clientID.isEmpty && !clientSecret.isEmpty && vcpPrivateKeyPEM != nil"
  echo "    }"
  echo "}"
} > Sources/TesBar/BuildConfig.swift

# 公钥自检（ADR-0004）：内置私钥推导 SPKI vs 线上 .well-known，不一致仅警告。
if [ -n "$private_pem" ]; then
  tmp_priv="$(mktemp)"
  printf '%s\n' "$private_pem" > "$tmp_priv"
  derived="$(openssl ec -in "$tmp_priv" -pubout 2>/dev/null | awk 'NF' | tail -n +2)"
  hosted="$(curl -fsSL "https://$pairing_domain/.well-known/appspecific/com.tesla.3p.public-key.pem" 2>/dev/null | awk 'NF' | tail -n +2)"
  rm -f "$tmp_priv"
  if [ -n "$hosted" ] && [ "$derived" != "$hosted" ]; then
    echo "⚠️  内置私钥与 $pairing_domain 托管公钥不匹配——车辆会拒绝签名指令（需重新配对或换托管公钥）" >&2
  fi
fi

# CLT 缺 libSwiftUIMacros.dylib，插件在 /tmp/tesbar-plugins（见 README 构建说明）。
plugin_flags=(
  -Xswiftc -Xfrontend -Xswiftc -external-plugin-path
  -Xswiftc -Xfrontend -Xswiftc "/tmp/tesbar-plugins#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server"
)

echo "==> swift build -c release"
swift build -c release --jobs 1 "${plugin_flags[@]}"

app="build/TesBar.app"
contents="$app/Contents"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"

echo "==> Info.plist"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>TesBar</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleGetInfoString</key><string>TesBar ${version}</string>
	<key>CFBundleIdentifier</key><string>com.tesbar.app</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>TesBar</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${version}</string>
	<key>CFBundleVersion</key><string>${build_number}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> copy binary"
cp "$(swift build -c release --show-bin-path)/TesBar" "$contents/MacOS/TesBar"

echo "==> copy icon resources"
cp Sources/TesBar/Resources/AppIcon.icns "$contents/Resources/AppIcon.icns"
cp Sources/TesBar/Resources/MenuIconTemplate.png "$contents/Resources/MenuIconTemplate.png"

echo "==> codesign (stable local identity)"
# Ad-hoc signing re-hashes every build, so keychain ACLs bound to the old build
# prompt on every read ("始终允许" never sticks). A fixed self-signed identity
# in a dedicated keychain keeps the ACL designator stable across rebuilds —
# one approval, done. Trust is NOT required for local runs (Gatekeeper aside),
# codesign accepts an untrusted self-signed identity.
identity="TesBar Local Signing"
sign_keychain="$HOME/Library/Keychains/tesbar-sign.keychain-db"
if ! security find-identity "$sign_keychain" 2>/dev/null | grep -q "$identity"; then
  echo "  creating self-signed codesigning identity (once)"
  tmpdir="$(mktemp -d)"
  cat > "$tmpdir/cert.conf" <<CERT
[req]
prompt = no
distinguished_name = dn
x509_extensions = ext
[dn]
CN = $identity
O = TesBar
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
CERT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmpdir/key.pem" -out "$tmpdir/cert.pem" \
    -config "$tmpdir/cert.conf" >/dev/null 2>&1
  openssl pkcs12 -export -out "$tmpdir/identity.p12" \
    -inkey "$tmpdir/key.pem" -in "$tmpdir/cert.pem" -passout pass:tesbar-sign \
    >/dev/null 2>&1
  security create-keychain -p tesbar-sign "$sign_keychain" >/dev/null 2>&1 || true
  security import "$tmpdir/identity.p12" -k "$sign_keychain" -P tesbar-sign \
    -A -T /usr/bin/codesign >/dev/null 2>&1
  security set-key-partition-list -S apple-tool:,apple: -s -k tesbar-sign \
    "$sign_keychain" >/dev/null 2>&1
  # Make codesign see the keychain without permanently touching the search list.
  security list-keychain -s ~/Library/Keychains/login.keychain-db "$sign_keychain" >/dev/null 2>&1
  rm -rf "$tmpdir"
fi
if codesign --force --deep -s "$identity" --keychain "$sign_keychain" --options runtime "$app" 2>/dev/null; then
  codesign -dv "$app" 2>&1 | grep -q "Authority=$identity" && echo "  signed with $identity"
else
  echo "warning: 稳定签名失败，退回 ad-hoc（keychain 会反复弹窗）" >&2
  codesign --force --deep -s - --options runtime "$app" || \
    echo "warning: codesign 失败，App 未签名（不影响本地使用）" >&2
fi

echo "==> ${repo_root}/${app}"
