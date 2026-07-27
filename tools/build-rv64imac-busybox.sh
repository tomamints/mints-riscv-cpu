#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUSYBOX_SRC:=$repo_root/build/toolchain-src/busybox}"
: "${TOOLCHAIN_PREFIX:=$repo_root/build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-}"
: "${OUT_DIR:=$repo_root/build/busybox-out/rv64imac-lp64}"
: "${JOBS:=8}"

cc="${TOOLCHAIN_PREFIX}gcc"
readelf="${TOOLCHAIN_PREFIX}readelf"

if [[ ! -x "$cc" ]]; then
  echo "missing compiler: $cc" >&2
  echo "run tools/build-rv64imac-musl-toolchain.sh first" >&2
  exit 1
fi

if [[ ! -d "$BUSYBOX_SRC" ]]; then
  echo "missing BusyBox source: $BUSYBOX_SRC" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

make -C "$BUSYBOX_SRC" O="$OUT_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$TOOLCHAIN_PREFIX" \
  defconfig

scripts_config="$BUSYBOX_SRC/scripts/config"
"$scripts_config" --file "$OUT_DIR/.config" -e STATIC
"$scripts_config" --file "$OUT_DIR/.config" -d FEATURE_PREFER_APPLETS

make -C "$BUSYBOX_SRC" O="$OUT_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$TOOLCHAIN_PREFIX" \
  KCFLAGS="-march=rv64imac -mabi=lp64" \
  -j"$JOBS" busybox

file "$OUT_DIR/busybox"
"$readelf" -h "$OUT_DIR/busybox" | rg 'Flags|Class|Machine|Type'
