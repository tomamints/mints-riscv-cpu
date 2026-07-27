#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${RISCV_GNU_TOOLCHAIN_SRC:=$HOME/riscv-gnu-toolchain}"
: "${BUILD_DIR:=$repo_root/build/riscv-musl-lp64-build-docker}"
: "${PREFIX:=$repo_root/build/riscv-musl-lp64}"
: "${MUSL_SRC:=$repo_root/build/toolchain-src/musl}"
: "${JOBS:=8}"

case "$RISCV_GNU_TOOLCHAIN_SRC" in
  /*) ;;
  *) RISCV_GNU_TOOLCHAIN_SRC="$repo_root/$RISCV_GNU_TOOLCHAIN_SRC" ;;
esac

case "$BUILD_DIR" in
  /*) ;;
  *) BUILD_DIR="$repo_root/$BUILD_DIR" ;;
esac

case "$PREFIX" in
  /*) ;;
  *) PREFIX="$repo_root/$PREFIX" ;;
esac

case "$MUSL_SRC" in
  /*) ;;
  *) MUSL_SRC="$repo_root/$MUSL_SRC" ;;
esac

if [[ ! -d "$RISCV_GNU_TOOLCHAIN_SRC/gcc" ]]; then
  echo "missing GCC source: $RISCV_GNU_TOOLCHAIN_SRC/gcc" >&2
  exit 1
fi

if [[ ! -d "$RISCV_GNU_TOOLCHAIN_SRC/binutils" ]]; then
  echo "missing binutils source: $RISCV_GNU_TOOLCHAIN_SRC/binutils" >&2
  exit 1
fi

if [[ ! -d "$MUSL_SRC" ]]; then
  echo "missing musl source: $MUSL_SRC" >&2
  echo "populate it first, for example from the riscv-gnu-toolchain musl submodule" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$PREFIX"

docker run --rm \
  -v "$repo_root:/repo" \
  -v "$RISCV_GNU_TOOLCHAIN_SRC:/riscv-gnu-toolchain-src" \
  -v "$BUILD_DIR:/toolchain-build" \
  -v "$PREFIX:/toolchain-prefix" \
  -v "$MUSL_SRC:/musl-src" \
  -w /repo \
  ubuntu:24.04 \
  bash -lc "
    set -euo pipefail
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      autoconf automake autotools-dev curl python3 python3-tomli \
      libmpc-dev libmpfr-dev libgmp-dev libisl-dev gawk build-essential \
      bison flex texinfo gperf libtool patchutils bc zlib1g-dev \
      libexpat-dev git make ca-certificates >/tmp/apt.log

    cd /toolchain-build
    if [[ ! -f Makefile ]]; then
      /riscv-gnu-toolchain-src/configure \
        --prefix=/toolchain-prefix \
        --with-arch=rv64imac \
        --with-abi=lp64 \
        --disable-gdb \
        --with-gcc-src=/riscv-gnu-toolchain-src/gcc \
        --with-binutils-src=/riscv-gnu-toolchain-src/binutils \
        --with-musl-src=/musl-src \
        --with-linux-headers-src=/riscv-gnu-toolchain-src/linux-headers/include
    fi

    make musl -j$JOBS MAKEINFO=true
  "

"$PREFIX/bin/riscv64-unknown-linux-musl-gcc" -v
