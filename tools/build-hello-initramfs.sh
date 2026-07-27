#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${RISCV_PREFIX:=/Users/shiraitouma/riscv/bin/riscv64-unknown-elf-}"
: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${OUT_DIR:=$repo_root/build/linux-user-init}"
: "${INIT_SRC:=$repo_root/platform/linux_user_init.S}"

gcc="${RISCV_PREFIX}gcc"
readelf="${RISCV_PREFIX}readelf"
objdump="${RISCV_PREFIX}objdump"

if command -v rg >/dev/null 2>&1; then
  grep_cmd=(rg)
else
  grep_cmd=(grep -E)
fi

if [[ ! -x "$gcc" ]]; then
  echo "missing compiler: $gcc" >&2
  exit 1
fi

if [[ ! -f "$LINUX_SRC/usr/gen_init_cpio.c" ]]; then
  echo "missing Linux gen_init_cpio source: $LINUX_SRC/usr/gen_init_cpio.c" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

"$gcc" \
  -march=rv64imac_zicsr \
  -mabi=lp64 \
  -mcmodel=medany \
  -nostdlib \
  -nostartfiles \
  -static \
  -Wl,--build-id=none \
  -Wl,-Ttext=0x10000 \
  "$INIT_SRC" \
  -o "$OUT_DIR/init"

cc "$LINUX_SRC/usr/gen_init_cpio.c" -o "$OUT_DIR/gen_init_cpio"

cat > "$OUT_DIR/initramfs.list" <<LIST
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
file /init $OUT_DIR/init 0755 0 0
LIST

"$OUT_DIR/gen_init_cpio" "$OUT_DIR/initramfs.list" > "$OUT_DIR/initramfs.cpio"

file "$OUT_DIR/init"
"$readelf" -h "$OUT_DIR/init" | "${grep_cmd[@]}" 'Class|Type|Machine|Flags'
"$readelf" -A "$OUT_DIR/init" || true
if "$objdump" -d "$OUT_DIR/init" | "${grep_cmd[@]}" '\b(fld|fsd|flw|fsw|fadd|fsub|fmul|fdiv|c\.fld|c\.fsd)\b'; then
  echo "unexpected F/D instruction found" >&2
  exit 1
fi

echo "$OUT_DIR/initramfs.cpio"
