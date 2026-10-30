#!/bin/bash
# Builds Clipwell.app. By default: a native release build installed to ~/Applications.
#
#   INSTALL=0 OUT_DIR=dist   build only; write dist/Clipwell.app (used by the release workflow)
#   UNIVERSAL=1              arm64 + x86_64 binary
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   default "-" (ad-hoc)
#   VERSION=1.2.3            default: nearest git tag, else 0.1.0
#   BUNDLE_ID=com.example.X  default io.github.naveenrenji.Clipwell; use your own for forks
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Clipwell"
BUNDLE_ID="${BUNDLE_ID:-io.github.naveenrenji.Clipwell}"
INSTALL="${INSTALL:-1}"
UNIVERSAL="${UNIVERSAL:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT_DIR="${OUT_DIR:-dist}"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_FLAGS=(-c release)
if [ "$UNIVERSAL" = "1" ]; then
    BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi

if [ "$INSTALL" = "1" ]; then
    DEST="$HOME/Applications/$APP_NAME.app"
else
    DEST="$OUT_DIR/$APP_NAME.app"
fi
STAGE="$(mktemp -d)/$APP_NAME.app"

swift build "${BUILD_FLAGS[@]}"
BIN="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/$APP_NAME"

ICON_KEY=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    $ICON_KEY
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Naveen Mathews Renji. MIT License.</string>
</dict>
</plist>
PLIST

# Hardened runtime: no unsigned code injection, no debugger attach. The app uses no network and
# no entitlements. A real Developer ID identity also gets a secure timestamp (needed to notarize).
SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" "$STAGE"
codesign --verify --strict "$STAGE"

if [ "$INSTALL" = "1" ]; then
    # Quit a running copy before replacing it.
    osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
    sleep 1
    mkdir -p "$HOME/Applications"
else
    mkdir -p "$OUT_DIR"
fi
rm -rf "$DEST"
cp -R "$STAGE" "$DEST"
echo "Built $DEST (version $VERSION, $(lipo -archs "$DEST/Contents/MacOS/$APP_NAME"))"
