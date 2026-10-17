#!/bin/bash
# TesBar.app 组装脚本（ticket 11，spec user story 36、ADR-0002）。
# 用法：在仓库根目录运行 ./Scripts/build-app.sh，产出 build/TesBar.app。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

version="$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)"
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

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
