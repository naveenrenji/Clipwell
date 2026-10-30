#!/bin/bash
# Builds a release binary and packages it as ~/Applications/Clipwell.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Clipwell"
BUNDLE_ID="${BUNDLE_ID:-io.github.naveenrenji.Clipwell}" # override with BUNDLE_ID=... to use your own
DEST="$HOME/Applications/$APP_NAME.app"
STAGE="$(mktemp -d)/$APP_NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

mkdir -p "$STAGE/Contents/MacOS"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Clipwell</string>
    <key>CFBundleDisplayName</key><string>Clipwell</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Naveen Mathews Renji. MIT License.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the hardened runtime: no unsigned code injection, no debugger attach.
# The app uses no network and no entitlements.
codesign --force --sign - --options runtime "$STAGE"
codesign --verify --strict "$STAGE"

# Quit a running copy before replacing it.
osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
mkdir -p "$HOME/Applications"
cp -R "$STAGE" "$DEST"
echo "Installed $DEST"
