#!/usr/bin/env bash
# build_both.sh -- build the default and ZisK-accelerated main guests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/guest/build"
SRC="$ROOT/guest/src/main.pnk"

mkdir -p "$BUILD_DIR"
env -u ACCEL "$ROOT/guest/build.sh" "$SRC" "$BUILD_DIR/guest.elf"
ACCEL=1 "$ROOT/guest/build.sh" "$SRC" "$BUILD_DIR/guest-accel.elf"
