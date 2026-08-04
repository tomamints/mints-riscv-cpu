#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${OPENSBI_SRC:=$repo_root/build/external/opensbi}"
: "${CROSS_COMPILE:=/Users/shiraitouma/riscv/bin/riscv64-unknown-elf-}"

wrapper_dir="$repo_root/build/toolchain-wrapper"
mkdir -p "$wrapper_dir"

cat > "$wrapper_dir/riscv64-unknown-elf-gcc" <<EOF
#!/usr/bin/env bash
exec ${CROSS_COMPILE}gcc -std=gnu11 "\$@"
EOF

chmod +x "$wrapper_dir/riscv64-unknown-elf-gcc"

for tool in ar as ld nm objcopy objdump ranlib; do
  ln -sf "${CROSS_COMPILE}${tool}" \
    "$wrapper_dir/riscv64-unknown-elf-${tool}"
done

rm -rf "$OPENSBI_SRC/build"

make -C "$OPENSBI_SRC" \
  PLATFORM=generic \
  CROSS_COMPILE="$wrapper_dir/riscv64-unknown-elf-"

echo "$OPENSBI_SRC/build/platform/generic/firmware/fw_jump.bin"
