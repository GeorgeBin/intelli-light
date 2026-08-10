#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSION_FILE="$REPO_DIR/VERSION"
APP_ID_FILE="$REPO_DIR/APP_ID"

read_metadata() {
    local file=$1 value
    [[ -f "$file" ]] || { printf 'Missing metadata file: %s\n' "$file" >&2; exit 1; }
    value=$(tr -d '\r\n' < "$file")
    [[ -n "$value" ]] || { printf 'Metadata file is empty: %s\n' "$file" >&2; exit 1; }
    printf '%s' "$value"
}

VERSION=$(read_metadata "$VERSION_FILE")
APP_ID=$(read_metadata "$APP_ID_FILE")
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid VERSION: %s\n' "$VERSION" >&2
    exit 1
fi
if [[ ! $APP_ID =~ ^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$ ]]; then
    printf 'Invalid APP_ID: %s\n' "$APP_ID" >&2
    exit 1
fi

CARGO_VERSION=$(awk '
    /^\[package\]$/ { package = 1; next }
    /^\[/ { package = 0 }
    package && /^version[[:space:]]*=/ { gsub(/["[:space:]]/, "", $3); print $3; exit }
' "$REPO_DIR/apps/linux/program/Cargo.toml")
[[ "$CARGO_VERSION" == "$VERSION" ]] || {
    printf 'Cargo.toml version mismatch: expected %s, found %s\n' "$VERSION" "$CARGO_VERSION" >&2
    exit 1
}

CARGO_LOCK_VERSION=$(awk '
    /^name = "intelli-light-linux"$/ { package = 1; next }
    package && /^version = / { gsub(/["[:space:]]/, "", $3); print $3; exit }
    package && /^\[/ { package = 0 }
' "$REPO_DIR/apps/linux/program/Cargo.lock")
[[ "$CARGO_LOCK_VERSION" == "$VERSION" ]] || {
    printf 'Cargo.lock version mismatch: expected %s, found %s\n' "$VERSION" "$CARGO_LOCK_VERSION" >&2
    exit 1
}

node - "$REPO_DIR/.codex-plugin/plugin.json" "$VERSION" <<'NODE'
const fs = require("node:fs");
const [manifestPath, version] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const expected = {
  name: "intelli-light",
  version,
  homepage: "https://github.com/GeorgeBin/intelli-light",
  repository: "https://github.com/GeorgeBin/intelli-light",
  displayName: "Intelli Light",
  developerName: "GeorgeBin",
};
for (const [path, value] of Object.entries(expected)) {
  const actual = path === "displayName" || path === "developerName"
    ? manifest.interface?.[path]
    : manifest[path];
  if (actual !== value) {
    throw new Error(`plugin.json ${path} mismatch: expected ${value}, found ${actual}`);
  }
}
NODE

for hook in "$REPO_DIR/hooks/codex/lifecycle.js" "$REPO_DIR/hooks/claude/claude-lifecycle.js"; do
    hook_app_id=$(sed -n 's/^const BUNDLE_ID = "\([^"]*\)";.*/\1/p' "$hook")
    [[ "$hook_app_id" == "$APP_ID" ]] || {
        printf 'Hook App ID mismatch in %s: expected %s, found %s\n' "$hook" "$APP_ID" "$hook_app_id" >&2
        exit 1
    }
done

case "${1:-}" in
    "") ;;
    --mac-app)
        app_dir=${2:?usage: check-metadata.sh --mac-app APP_DIR}
        plist="$app_dir/Contents/Info.plist"
        [[ -f "$plist" ]] || { printf 'Missing macOS Info.plist: %s\n' "$plist" >&2; exit 1; }
        plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
        plist_app_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
        [[ "$plist_version" == "$VERSION" && "$plist_app_id" == "$APP_ID" ]] || {
            printf 'macOS metadata mismatch: version=%s app_id=%s\n' "$plist_version" "$plist_app_id" >&2
            exit 1
        }
        ;;
    --linux-build)
        build_dir=${2:?usage: check-metadata.sh --linux-build BUILD_DIR}
        header="$build_dir/generated/AppMetadata.h"
        desktop="$build_dir/$APP_ID.desktop"
        grep -Fq "INTELLI_LIGHT_VERSION \"$VERSION\"" "$header"
        grep -Fq "INTELLI_LIGHT_APP_ID \"$APP_ID\"" "$header"
        [[ -f "$desktop" ]] || { printf 'Missing generated Desktop file: %s\n' "$desktop" >&2; exit 1; }
        ;;
    --debian-control)
        control=${2:?usage: check-metadata.sh --debian-control CONTROL}
        deb_version=$(sed -n 's/^Version: //p' "$control")
        [[ "$deb_version" == "$VERSION" ]] || {
            printf 'Debian metadata mismatch: expected %s, found %s\n' "$VERSION" "$deb_version" >&2
            exit 1
        }
        ;;
    *)
        printf 'Unknown metadata check option: %s\n' "$1" >&2
        exit 2
        ;;
esac

printf 'Metadata OK: VERSION=%s APP_ID=%s\n' "$VERSION" "$APP_ID"
