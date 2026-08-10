#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Intelli Light.app"
BIN="$APP/Contents/MacOS/IntelliLight"

"$REPO_DIR/scripts/check-metadata.sh"
VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION")
APP_ID=$(tr -d '\r\n' < "$REPO_DIR/APP_ID")

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "Compiling universal macOS 12+ application..."
SWIFT_SOURCES=(
    "$REPO_DIR/apps/macos/program"/*.swift
    "$REPO_DIR/apps/macos/ui"/*.swift
    "$REPO_DIR/apps/macos/led"/*.swift
)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_DIR/module-cache}"
swiftc -O -target arm64-apple-macos12.0 "${SWIFT_SOURCES[@]}" -o "$BIN.arm64" -framework Cocoa
swiftc -O -target x86_64-apple-macos12.0 "${SWIFT_SOURCES[@]}" -o "$BIN.x86_64" -framework Cocoa
lipo -create "$BIN.arm64" "$BIN.x86_64" -o "$BIN"
rm "$BIN.arm64" "$BIN.x86_64"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Intelli Light</string>
  <key>CFBundleDisplayName</key><string>Intelli Light</string>
  <key>CFBundleIdentifier</key><string>${APP_ID}</string>
  <key>CFBundleExecutable</key><string>IntelliLight</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp "$REPO_DIR/hooks/codex/update.js" "$REPO_DIR/hooks/codex/lifecycle.js" \
   "$REPO_DIR/hooks/claude/claude-update.js" "$REPO_DIR/hooks/claude/claude-lifecycle.js" \
   "$REPO_DIR/hooks/install.js" "$REPO_DIR/hooks/uninstall.js" "$REPO_DIR/hooks/fs-utils.js" \
   "$APP/Contents/Resources/"
cp "$REPO_DIR/apps/macos/ui/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$REPO_DIR/NOTICE" "$REPO_DIR/LICENSE" "$APP/Contents/Resources/"

"$REPO_DIR/scripts/check-metadata.sh" --mac-app "$APP"
printf 'Built %s\n' "$APP"
