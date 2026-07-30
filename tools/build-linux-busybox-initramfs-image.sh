#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${LINUX_SRC_VOLUME:=}"
: "${LINUX_OUT:=$repo_root/build/linux-out}"
: "${INIT_SCRIPT_MODE:=default}"
: "${KBUILD_OUT:=$repo_root/build/linux-build-busybox-$INIT_SCRIPT_MODE}"
: "${IMAGE_NAME:=Image-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs}"
: "${INITRAMFS_OUT:=$repo_root/build/busybox-initramfs-$INIT_SCRIPT_MODE}"
: "${BUSYBOX_BIN:=$repo_root/build/busybox-out/rv64imac-lp64/busybox}"
: "${JOBS:=8}"
: "${DUMP_INIT:=0}"
: "${LINUX_PREEMPT:=keep}"

if [[ -z "$LINUX_SRC_VOLUME" ]]; then
  case "$LINUX_SRC" in
    /*) ;;
    *) LINUX_SRC="$repo_root/$LINUX_SRC" ;;
  esac
fi

case "$LINUX_OUT" in
  /*) ;;
  *) LINUX_OUT="$repo_root/$LINUX_OUT" ;;
esac

case "$KBUILD_OUT" in
  /*) ;;
  *) KBUILD_OUT="$repo_root/$KBUILD_OUT" ;;
esac

case "$INITRAMFS_OUT" in
  /*) ;;
  *) INITRAMFS_OUT="$repo_root/$INITRAMFS_OUT" ;;
esac

case "$BUSYBOX_BIN" in
  /*) ;;
  *) BUSYBOX_BIN="$repo_root/$BUSYBOX_BIN" ;;
esac

if [[ -z "$LINUX_SRC_VOLUME" && ! -d "$LINUX_SRC" ]]; then
  echo "missing Linux source: $LINUX_SRC" >&2
  exit 1
fi

if [[ ! -x "$BUSYBOX_BIN" ]]; then
  echo "missing BusyBox binary: $BUSYBOX_BIN" >&2
  echo "run tools/build-rv64imac-busybox.sh first" >&2
  exit 1
fi

if [[ -z "$LINUX_SRC_VOLUME" && ! -f "$LINUX_SRC/usr/gen_init_cpio.c" ]]; then
  echo "missing Linux gen_init_cpio source: $LINUX_SRC/usr/gen_init_cpio.c" >&2
  exit 1
fi

build_initramfs_env=(
  INIT_SCRIPT_MODE="$INIT_SCRIPT_MODE"
  OUT_DIR="$INITRAMFS_OUT"
  BUSYBOX_BIN="$BUSYBOX_BIN"
  DUMP_INIT="$DUMP_INIT"
  SKIP_CPIO=1
)

if [[ -n "$LINUX_SRC_VOLUME" ]]; then
  build_initramfs_env+=(LINUX_SRC="$repo_root/build/external/linux")
else
  build_initramfs_env+=(LINUX_SRC="$LINUX_SRC")
fi

env "${build_initramfs_env[@]}" "$repo_root/tools/build-busybox-initramfs.sh"

mkdir -p "$LINUX_OUT"
mkdir -p "$KBUILD_OUT"

case "$LINUX_OUT" in
  "$repo_root"/*) linux_out_repo="/repo/${LINUX_OUT#"$repo_root"/}" ;;
  *) echo "LINUX_OUT must be inside repo: $LINUX_OUT" >&2; exit 1 ;;
esac

case "$KBUILD_OUT" in
  "$repo_root"/*) kbuild_out_repo="/repo/${KBUILD_OUT#"$repo_root"/}" ;;
  *) echo "KBUILD_OUT must be inside repo: $KBUILD_OUT" >&2; exit 1 ;;
esac

case "$INITRAMFS_OUT" in
  "$repo_root"/*) initramfs_out_repo="/repo/${INITRAMFS_OUT#"$repo_root"/}" ;;
  *) echo "INITRAMFS_OUT must be inside repo: $INITRAMFS_OUT" >&2; exit 1 ;;
esac

docker_args=(
  --rm
  -v "$repo_root:/repo"
)

if [[ -n "$LINUX_SRC_VOLUME" ]]; then
  docker_args+=(-v "$LINUX_SRC_VOLUME:/linux-src")
else
  docker_args+=(-v "$LINUX_SRC:/linux-src")
fi

docker run "${docker_args[@]}" \
  -w /repo \
  ubuntu:24.04 \
  bash -lc "
    set -euo pipefail
    if [[ ! -f /linux-src/Makefile ]]; then
      echo 'missing Linux source in /linux-src' >&2
      echo 'set LINUX_SRC to a Linux tree, or populate LINUX_SRC_VOLUME first' >&2
      exit 1
    fi
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      bc bison flex make gcc gcc-riscv64-linux-gnu \
      libssl-dev libelf-dev dwarves ca-certificates >/tmp/apt.log

    mkdir -p $linux_out_repo $kbuild_out_repo

    if [[ -f $linux_out_repo/config-linux-6.12-riscv64-minbringup ]]; then
      cp $linux_out_repo/config-linux-6.12-riscv64-minbringup $kbuild_out_repo/.config
    else
      make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- allnoconfig
      /linux-src/scripts/kconfig/merge_config.sh -m $kbuild_out_repo/.config /repo/platform/linux_minbringup.fragment
    fi

    /linux-src/scripts/config --file $kbuild_out_repo/.config \
      -e BLK_DEV_INITRD \
      -e BINFMT_ELF \
      -e BINFMT_SCRIPT \
      --set-str INITRAMFS_SOURCE $initramfs_out_repo/initramfs.linux.list

    case \"$LINUX_PREEMPT\" in
      keep)
        ;;
      none)
        /linux-src/scripts/config --file $kbuild_out_repo/.config \
          -e PREEMPT_NONE \
          -d PREEMPT_VOLUNTARY \
          -d PREEMPT
        ;;
      voluntary)
        /linux-src/scripts/config --file $kbuild_out_repo/.config \
          -d PREEMPT_NONE \
          -e PREEMPT_VOLUNTARY \
          -d PREEMPT
        ;;
      full)
        /linux-src/scripts/config --file $kbuild_out_repo/.config \
          -d PREEMPT_NONE \
          -d PREEMPT_VOLUNTARY \
          -e PREEMPT
        ;;
      *)
        echo 'LINUX_PREEMPT must be one of: keep, none, voluntary, full' >&2
        exit 1
        ;;
    esac

    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$JOBS Image

    cp $kbuild_out_repo/arch/riscv/boot/Image $linux_out_repo/$IMAGE_NAME
    cp $kbuild_out_repo/vmlinux $linux_out_repo/vmlinux-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs
    cp $kbuild_out_repo/System.map $linux_out_repo/System.map-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs
    cp $kbuild_out_repo/.config $linux_out_repo/config-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs
  "

echo "$LINUX_OUT/$IMAGE_NAME"
