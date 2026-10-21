#!/bin/zsh
# Builds Headroom.app next to this script.
# Usage: ./build.sh [--install | --release]
#   --install  copy the app to /Applications
#   --release  also zip it to build/Headroom.zip for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

VERSION=1.0
APP=build/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple silicon and Intel.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
    Sources/main.swift -o "build/Headroom-$arch"
done
lipo -create build/Headroom-arm64 build/Headroom-x86_64 -output "$APP/Contents/MacOS/Headroom"
rm build/Headroom-arm64 build/Headroom-x86_64

[[ -f Assets/AppIcon.icns ]] || swift scripts/make-icon.swift .
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>app.headroom.menubar</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
  <key>CFBundleVersion</key><string>VERSION_PLACEHOLDER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
sed -i '' "s/VERSION_PLACEHOLDER/$VERSION/g" "$APP/Contents/Info.plist"

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Headroom"))"

if [[ "${1:-}" == "--release" ]]; then
  rm -f build/Headroom.zip
  ditto -c -k --keepParent "$APP" build/Headroom.zip
  echo "Packaged build/Headroom.zip (v$VERSION)"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Headroom 2>/dev/null || true
  rm -rf /Applications/Headroom.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Headroom.app"
fi
