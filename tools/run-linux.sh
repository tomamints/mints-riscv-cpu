#!/usr/bin/env bash
# Starts the simulator; rebuilding dependencies is a separate command.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
: "${DOCKER_IMAGE:=mints-linux-verilator:5.046}"
: "${OPENSBI_CYCLES:=300000000}"
mkdir -p build/logs
tty_args=(-i)
if [[ -t 0 && -t 1 ]]; then tty_args+=(-t); fi
docker run --rm --init "${tty_args[@]}" -v "$PWD:/repo" \
  -e OPENSBI_CYCLES="$OPENSBI_CYCLES" "$DOCKER_IMAGE" bash -c '
    set -euo pipefail
    make run-opensbi-input DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=0 \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES="$OPENSBI_CYCLES" SIM_EXTRA_ARGS=+PERF_SUMMARY \
      2>&1 | tee build/logs/linux-boot.log
    if [[ "$OPENSBI_CYCLES" != 0 ]]; then
      grep -q BUSYBOX-TEST-PASS build/logs/linux-boot.log
      ! grep -qE "BUSYBOX-TEST-FAIL|Kernel panic" build/logs/linux-boot.log
    fi
  '
