#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
MANIFEST="$SCRIPT_DIR/program/Cargo.toml"
DESKTOP_BUILD_DIR="$SCRIPT_DIR/build/ui"
export CARGO_TARGET_DIR="$SCRIPT_DIR/build/cargo"

"$REPO_DIR/scripts/check-metadata.sh"
VERSION=$(tr -d '\r\n' < "$REPO_DIR/VERSION")
APP_ID=$(tr -d '\r\n' < "$REPO_DIR/APP_ID")

cargo clean --manifest-path "$MANIFEST"
cargo fmt --manifest-path "$MANIFEST" --check
cargo clippy --manifest-path "$MANIFEST" --all-targets -- -D warnings
cargo test --manifest-path "$MANIFEST"
cargo build --manifest-path "$MANIFEST" --release

cmake_args=(
    -S "$SCRIPT_DIR/ui"
    -B "$DESKTOP_BUILD_DIR"
    --fresh
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX=/usr
    -DINTELLI_LIGHT_EXPECTED_VERSION="$VERSION"
    -DINTELLI_LIGHT_EXPECTED_APP_ID="$APP_ID"
)
if [[ -n ${GETTEXT_MSGMERGE_EXECUTABLE:-} ]]; then
    cmake_args+=("-DGETTEXT_MSGMERGE_EXECUTABLE=$GETTEXT_MSGMERGE_EXECUTABLE")
fi
if [[ -n ${GETTEXT_MSGFMT_EXECUTABLE:-} ]]; then
    cmake_args+=("-DGETTEXT_MSGFMT_EXECUTABLE=$GETTEXT_MSGFMT_EXECUTABLE")
fi
cmake "${cmake_args[@]}"
"$REPO_DIR/scripts/check-metadata.sh" --linux-build "$DESKTOP_BUILD_DIR"
cmake --build "$DESKTOP_BUILD_DIR" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-1}"
ctest --test-dir "$DESKTOP_BUILD_DIR" --output-on-failure

printf 'Linux build complete:\n  %s\n  %s\n' \
    "$SCRIPT_DIR/build/cargo/release/intelli-light-linux" \
    "$DESKTOP_BUILD_DIR/bin/intelli-light-desktop"
