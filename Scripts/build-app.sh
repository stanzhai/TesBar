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

echo "==> codesign (ad-hoc, best-effort)"
if ! codesign --force --deep -s - --options runtime "$app"; then
  echo "warning: codesign 失败，App 未签名（不影响本地使用）" >&2
fi

echo "==> ${repo_root}/${app}"
