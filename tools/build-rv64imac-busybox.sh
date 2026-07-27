#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUSYBOX_SRC:=$repo_root/build/toolchain-src/busybox}"
: "${TOOLCHAIN_PREFIX:=$repo_root/build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-}"
: "${OUT_DIR:=$repo_root/build/busybox-out/rv64imac-lp64}"
: "${JOBS:=8}"

cc="${TOOLCHAIN_PREFIX}gcc"
readelf="${TOOLCHAIN_PREFIX}readelf"
objdump="${TOOLCHAIN_PREFIX}objdump"

if command -v rg >/dev/null 2>&1; then
  grep_cmd=(rg)
else
  grep_cmd=(grep -E)
fi

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
rm -f "$OUT_DIR/.config"

make -C "$BUSYBOX_SRC" O="$OUT_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$TOOLCHAIN_PREFIX" \
  defconfig

set_config() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=|^# ${key} is not set" "$OUT_DIR/.config"; then
    perl -0pi -e "s/^${key}=.*$/${key}=${value}/m; s/^# ${key} is not set$/${key}=${value}/m" "$OUT_DIR/.config"
  else
    printf '%s=%s\n' "$key" "$value" >> "$OUT_DIR/.config"
  fi
}

unset_config() {
  local key="$1"
  if grep -qE "^${key}=|^# ${key} is not set" "$OUT_DIR/.config"; then
    perl -0pi -e "s/^${key}=.*$/# ${key} is not set/m" "$OUT_DIR/.config"
  else
    printf '# %s is not set\n' "$key" >> "$OUT_DIR/.config"
  fi
}

set_config CONFIG_STATIC y
unset_config CONFIG_FEATURE_PREFER_APPLETS
unset_config CONFIG_TC
unset_config CONFIG_FEATURE_TC_INGRESS

set +o pipefail
yes "" | make -C "$BUSYBOX_SRC" O="$OUT_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$TOOLCHAIN_PREFIX" \
  oldconfig
set -o pipefail

make -C "$BUSYBOX_SRC" O="$OUT_DIR" \
  ARCH=riscv \
  CROSS_COMPILE="$TOOLCHAIN_PREFIX" \
  KCFLAGS="-march=rv64imac -mabi=lp64" \
  -j"$JOBS" busybox

file "$OUT_DIR/busybox"
"$readelf" -h "$OUT_DIR/busybox" | "${grep_cmd[@]}" 'Flags|Class|Machine|Type'
"$readelf" -A "$OUT_DIR/busybox" || true
if "$objdump" -d "$OUT_DIR/busybox" | "${grep_cmd[@]}" '\b(fld|fsd|flw|fsw|fadd|fsub|fmul|fdiv|c\.fld|c\.fsd)\b'; then
  echo "unexpected F/D instruction found" >&2
  exit 1
fi
