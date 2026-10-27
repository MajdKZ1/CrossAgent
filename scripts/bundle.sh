#!/bin/sh
# Wraps the release binary into CrossAgent.app (ad hoc signed).
# Usage: swift build -c release && scripts/bundle.sh [output dir]
set -eu
cd "$(dirname "$0")/.."
OUT="${1:-build}"
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/CrossAgent"
[ -x "$BIN" ] || { echo "no release binary, run: swift build -c release" >&2; exit 1; }

APP="$OUT/CrossAgent.app"
VERSION="0.1.0"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CrossAgent"
# SwiftPM resource bundles (if any dependency ships one) sit next to the binary.
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
# Static asset, never generated here. To update: iconutil -c icns assets/icon/CrossAgent.iconset -o assets/AppIcon.icns
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CrossAgent</string>
    <key>CFBundleDisplayName</key><string>CrossAgent</string>
    <key>CFBundleIdentifier</key><string>dev.crossagent</string>
    <key>CFBundleExecutable</key><string>CrossAgent</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "codesign skipped" >&2
echo "built $APP"
