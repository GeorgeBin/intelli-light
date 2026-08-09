#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DESKTOP_BUILD_DIR="$SCRIPT_DIR/build/desktop"

cd "$SCRIPT_DIR"
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo build --release

cmake_args=(
    -S "$SCRIPT_DIR/desktop"
    -B "$DESKTOP_BUILD_DIR"
    --fresh
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX=/usr
)
if [[ -n ${GETTEXT_MSGMERGE_EXECUTABLE:-} ]]; then
    cmake_args+=("-DGETTEXT_MSGMERGE_EXECUTABLE=$GETTEXT_MSGMERGE_EXECUTABLE")
fi
if [[ -n ${GETTEXT_MSGFMT_EXECUTABLE:-} ]]; then
    cmake_args+=("-DGETTEXT_MSGFMT_EXECUTABLE=$GETTEXT_MSGFMT_EXECUTABLE")
fi
cmake "${cmake_args[@]}"
cmake --build "$DESKTOP_BUILD_DIR" --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-1}"
ctest --test-dir "$DESKTOP_BUILD_DIR" --output-on-failure

printf 'Linux build complete:\n  %s\n  %s\n' \
    "$SCRIPT_DIR/target/release/intelli-light-linux" \
    "$DESKTOP_BUILD_DIR/bin/intelli-light-desktop"
