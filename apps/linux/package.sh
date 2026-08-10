#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
DIST_DIR="$SCRIPT_DIR/dist"
DESKTOP_BUILD_DIR="$SCRIPT_DIR/build/ui"
VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION")
APP_ID=$(tr -d '\r\n' < "$REPO_DIR/APP_ID")

"$REPO_DIR/scripts/check-metadata.sh"
if [[ ${INTELLI_LIGHT_SKIP_BUILD:-0} != 1 ]]; then
    "$SCRIPT_DIR/build.sh"
fi

ARCH=$(dpkg --print-architecture)
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([+~-][A-Za-z0-9.+~-]+)?$ ]]; then
    printf 'Invalid package version: %s\n' "$VERSION" >&2
    exit 1
fi
if [[ $ARCH != amd64 && $ARCH != arm64 ]]; then
    printf 'Unsupported Debian architecture: %s (supported: amd64, arm64)\n' "$ARCH" >&2
    exit 1
fi
test -x "$SCRIPT_DIR/build/cargo/release/intelli-light-linux"
test -x "$DESKTOP_BUILD_DIR/bin/intelli-light-desktop"
"$REPO_DIR/scripts/check-metadata.sh" --linux-build "$DESKTOP_BUILD_DIR"

mkdir -p "$DIST_DIR"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/intelli-light-deb.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
chmod 0755 "$STAGE"

install -Dm755 "$SCRIPT_DIR/build/cargo/release/intelli-light-linux" \
    "$STAGE/usr/bin/intelli-light-linux"
DESTDIR="$STAGE" cmake --install "$DESKTOP_BUILD_DIR" --prefix /usr
if readelf -d "$STAGE/usr/bin/intelli-light-desktop" | grep -Eq 'RPATH|RUNPATH'; then
    printf 'Refusing to package a Desktop binary with an embedded RPATH/RUNPATH\n' >&2
    exit 1
fi
if ldd "$STAGE/usr/bin/intelli-light-desktop" | grep -q 'not found'; then
    printf 'Refusing to package a Desktop binary with unresolved libraries\n' >&2
    exit 1
fi
install -Dm644 "$SCRIPT_DIR/packaging/systemd/intelli-light.service" \
    "$STAGE/usr/lib/systemd/user/intelli-light.service"
for hook in \
    hooks/fs-utils.js \
    hooks/codex/update.js \
    hooks/claude/claude-update.js \
    hooks/linux/linux-lifecycle.js; do
    install -Dm644 "$REPO_DIR/$hook" \
        "$STAGE/usr/share/intelli-light/hooks/$(basename "$hook")"
done
install -Dm644 "$REPO_DIR/LICENSE" "$STAGE/usr/share/doc/intelli-light/LICENSE"
install -Dm644 "$SCRIPT_DIR/README.md" "$STAGE/usr/share/doc/intelli-light/README.Debian"
install -Dm644 "$REPO_DIR/docs/linux-debian13.md" \
    "$STAGE/usr/share/doc/intelli-light/linux-debian13.md"
install -Dm644 "$SCRIPT_DIR/packaging/debian/copyright" \
    "$STAGE/usr/share/doc/intelli-light/copyright"
find "$STAGE/usr" -type d -exec chmod 0755 {} +

mkdir -p "$STAGE/DEBIAN"
INSTALLED_SIZE=$(du -sk "$STAGE/usr" | awk '{print $1}')
sed \
    -e "s/@VERSION@/$VERSION/g" \
    -e "s/@ARCH@/$ARCH/g" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/g" \
    "$SCRIPT_DIR/packaging/debian/control.in" > "$STAGE/DEBIAN/control"
chmod 0644 "$STAGE/DEBIAN/control"
"$REPO_DIR/scripts/check-metadata.sh" --debian-control "$STAGE/DEBIAN/control"

test -f "$STAGE/usr/share/applications/$APP_ID.desktop"

OUTPUT="$DIST_DIR/intelli-light_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUTPUT"
printf '%s\n' "$OUTPUT"
