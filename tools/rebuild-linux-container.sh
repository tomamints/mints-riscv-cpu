#!/usr/bin/env bash
# Run via tools/rebuild-linux.sh, inside the Linux build container.
set -euo pipefail
cd /repo
: "${JOBS:=4}"
mkdir -p build/logs build/external build/toolchain-src

stage="${1:-all}"
sources() {
  if [[ ! -f /sources/linux-6.12/Makefile ]]; then
    curl -fL --retry 3 https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.tar.xz -o /sources/linux-6.12.tar.xz
    echo 'b1a2562be56e42afb3f8489d4c2a7ac472ac23098f1ef1c1e40da601f54625eb  /sources/linux-6.12.tar.xz' | sha256sum -c -
    tar -xJf /sources/linux-6.12.tar.xz -C /sources
  fi
  if [[ ! -d build/external/opensbi/.git ]]; then
    git clone --depth 1 --branch v1.3.1 https://github.com/riscv-software-src/opensbi.git build/external/opensbi
  fi
  if [[ ! -f build/toolchain-src/busybox/Makefile ]]; then
    curl -fL --retry 3 https://busybox.net/downloads/busybox-1.36.1.tar.bz2 -o /sources/busybox-1.36.1.tar.bz2
    echo 'b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314  /sources/busybox-1.36.1.tar.bz2' | sha256sum -c -
    mkdir -p build/toolchain-src/busybox
    tar -xjf /sources/busybox-1.36.1.tar.bz2 --strip-components=1 -C build/toolchain-src/busybox
  fi
  if [[ ! -f /sources/musl-cross-make/Makefile ]]; then
    curl -fL --retry 3 https://codeload.github.com/richfelker/musl-cross-make/tar.gz/5e8042e63de29f8473fc3b0b831a587ba284e1a8 -o /sources/musl-cross-make.tar.gz
    mkdir -p /sources/musl-cross-make
    tar -xzf /sources/musl-cross-make.tar.gz --strip-components=1 -C /sources/musl-cross-make
  fi
}

toolchain() {
  cat > /sources/musl-cross-make/config.mak <<'CONFIG'
TARGET = riscv64-linux-musl
OUTPUT = /repo/build/riscv-musl-lp64
GCC_VER = 13.3.0
MUSL_VER = 1.2.5
GMP_VER =
MPC_VER =
MPFR_VER =
DL_CMD = curl -fL --retry 3 -C - -o
GNU_SITE = https://ftp.gnu.org/gnu
COMMON_CONFIG += --disable-nls
GCC_CONFIG += --with-arch=rv64imac --with-abi=lp64 --enable-languages=c
GCC_CONFIG += --disable-libquadmath --disable-libgomp --disable-libsanitizer
CONFIG
  make -C /sources/musl-cross-make -j"$JOBS"
  make -C /sources/musl-cross-make install
  # The minimal headers bundled with musl-cross-make omit headers used by
  # BusyBox console applets (including linux/kd.h). Install the full UAPI.
  mkdir -p /repo/build/linux-headers-out
  make -C /sources/linux-6.12 O=/repo/build/linux-headers-out ARCH=riscv \
    INSTALL_HDR_PATH=/repo/build/riscv-musl-lp64/riscv64-linux-musl headers_install
}

firmware() {
  make -C build/external/opensbi PLATFORM=generic CROSS_COMPILE=riscv64-unknown-elf- -j"$JOBS"
  make dtb linux-bootrom-build
}

busybox() {
  local src=/repo/build/toolchain-src/busybox
  local out=/repo/build/busybox-out/rv64imac-lp64
  local cross=/repo/build/riscv-musl-lp64/bin/riscv64-linux-musl-
  mkdir -p "$out"
  make -C "$src" O="$out" defconfig
  sed -i -e 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
    -e 's/CONFIG_TC=y/# CONFIG_TC is not set/' \
    -e 's/CONFIG_FEATURE_PREFER_APPLETS=y/# CONFIG_FEATURE_PREFER_APPLETS is not set/' "$out/.config"
  make -C "$src" O="$out" ARCH=riscv CROSS_COMPILE="$cross" oldconfig </dev/null
  make -C "$src" O="$out" ARCH=riscv CROSS_COMPILE="$cross" \
    KCFLAGS='-march=rv64imac -mabi=lp64' -j"$JOBS" busybox
  "${cross}readelf" -h -A "$out/busybox"
}

kernel() {
  local out=/repo/build/linux-build-busybox-autotest
  INIT_SCRIPT_MODE=autotest SKIP_CPIO=1 bash tools/build-busybox-initramfs.sh
  mkdir -p "$out" build/external/linux-out
  make -C /sources/linux-6.12 O="$out" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- allnoconfig
  (cd "$out" && /sources/linux-6.12/scripts/kconfig/merge_config.sh -m .config /repo/platform/linux_minbringup.fragment)
  /sources/linux-6.12/scripts/config --file "$out/.config" \
    --set-str INITRAMFS_SOURCE /repo/build/busybox-initramfs-autotest/initramfs.linux.list
  make -C /sources/linux-6.12 O="$out" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
  make -C /sources/linux-6.12 O="$out" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j"$JOBS" Image
  cp "$out/arch/riscv/boot/Image" build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
  cp "$out/.config" build/external/linux-out/config-linux-6.12-riscv64-busybox-autotest-initramfs
}

simulator() {
  make -j"$JOBS" build-input DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=0
}

run_stage() {
  echo "MiNTs Linux rebuild: $1 (log: build/logs/$1.log)"
  "$1" 2>&1 | tee "build/logs/$1.log"
}
if [[ "$stage" == all ]]; then
  for item in sources toolchain firmware busybox kernel simulator; do run_stage "$item"; done
  make opensbi-ram-image \
    OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
    LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
  echo 'Build complete. Run Linux yourself with: bash tools/run-linux.sh'
else
  case "$stage" in
    sources|toolchain|firmware|busybox|kernel|simulator) run_stage "$stage" ;;
    *) echo "Unknown stage: $stage" >&2; exit 2 ;;
  esac
fi
