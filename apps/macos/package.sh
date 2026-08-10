#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
BUILD_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"
APP="$BUILD_DIR/Intelli Light.app"
VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION")
APP_ID=$(tr -d '\r\n' < "$REPO_DIR/APP_ID")

"$REPO_DIR/scripts/check-metadata.sh"
if [[ ${INTELLI_LIGHT_SKIP_BUILD:-0} != 1 ]]; then
    "$SCRIPT_DIR/build.sh"
fi
test -x "$APP/Contents/MacOS/IntelliLight"
"$REPO_DIR/scripts/check-metadata.sh" --mac-app "$APP"

TEAM_ID=${TEAM_ID:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-intelli-light}
SIGN_ID=""
if [[ -n "$TEAM_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | grep "$TEAM_ID" \
        | head -1 \
        | sed -E 's/.*"(.*)"/\1/' || true)"
fi

if [[ -n "$SIGN_ID" ]]; then
    echo "Signing with Developer ID: $SIGN_ID"
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
    echo "No Developer ID certificate found for team '$TEAM_ID'; using ad-hoc signing."
    codesign --force --sign - "$APP"
fi

if [[ ${SKIP_NOTARIZE:-0} != 1 && -n "$SIGN_ID" ]]; then
    echo "Notarizing the app with profile '$NOTARY_PROFILE'..."
    rm -f "$BUILD_DIR/app-notarize.zip"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/app-notarize.zip"
    xcrun notarytool submit "$BUILD_DIR/app-notarize.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$BUILD_DIR/app-notarize.zip"
fi

echo "Packaging DMG..."
DMG="$DIST_DIR/IntelliLight-${VERSION}.dmg"
STAGE="$BUILD_DIR/dmg-stage"
trap 'rm -rf -- "$STAGE" "$BUILD_DIR/rw.dmg" "$BUILD_DIR/app-notarize.zip"' EXIT
mkdir -p "$DIST_DIR"
rm -rf "$STAGE" "$DMG" "$BUILD_DIR/rw.dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Intelli Light" -srcfolder "$STAGE" \
    -ov -format UDRW "$BUILD_DIR/rw.dmg" >/dev/null
device="$(hdiutil attach -readwrite -noverify -noautoopen "$BUILD_DIR/rw.dmg" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
sleep 1
osascript <<'OSA' || echo "(Finder layout skipped; DMG still contains the app and Applications shortcut)"
tell application "Finder"
  tell disk "Intelli Light"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 880, 540}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 100
    set text size of vo to 12
    set position of item "Intelli Light.app" of container window to {130, 150}
    set position of item "Applications" of container window to {350, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
rm -rf "/Volumes/Intelli Light/.fseventsd" "/Volumes/Intelli Light/.Trashes" 2>/dev/null || true
sync
sleep 1
hdiutil detach "$device" >/dev/null || true
hdiutil convert "$BUILD_DIR/rw.dmg" -format UDZO -o "$DMG" >/dev/null
rm -rf "$BUILD_DIR/rw.dmg" "$STAGE"

if [[ -n "$SIGN_ID" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [[ ${SKIP_NOTARIZE:-0} != 1 ]]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

printf 'Built %s\n' "$DMG"
