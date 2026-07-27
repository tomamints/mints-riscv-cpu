#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${LINUX_OUT:=$repo_root/build/linux-out}"
: "${KBUILD_OUT:=$repo_root/build/linux-build-hello-clean}"
: "${KCONFIG_BASE:=$LINUX_OUT/config-linux-6.12-riscv64-minbringup}"
: "${IMAGE_NAME:=Image-linux-6.12-riscv64-hello-initramfs}"
: "${JOBS:=8}"

case "$LINUX_SRC" in
  /*) ;;
  *) LINUX_SRC="$repo_root/$LINUX_SRC" ;;
esac

case "$LINUX_OUT" in
  /*) ;;
  *) LINUX_OUT="$repo_root/$LINUX_OUT" ;;
esac

case "$KBUILD_OUT" in
  /*) ;;
  *) KBUILD_OUT="$repo_root/$KBUILD_OUT" ;;
esac

if [[ ! -d "$LINUX_SRC" ]]; then
  echo "missing Linux source: $LINUX_SRC" >&2
  exit 1
fi

"$repo_root/tools/build-hello-initramfs.sh" >/dev/null
sed "s|$repo_root|/repo|g" \
  "$repo_root/build/linux-user-init/initramfs.list" \
  > "$repo_root/build/linux-user-init/initramfs.linux.list"
mkdir -p "$LINUX_OUT"
mkdir -p "$KBUILD_OUT"

docker run --rm \
  -v "$repo_root:/repo" \
  -v "$LINUX_SRC:/linux-src" \
  -w /repo \
  ubuntu:24.04 \
  bash -lc "
    set -euo pipefail
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      bc bison flex make gcc gcc-riscv64-linux-gnu \
      libssl-dev libelf-dev dwarves ca-certificates >/tmp/apt.log

    if [[ -f /repo/build/linux-out/config-linux-6.12-riscv64-minbringup ]]; then
      cp /repo/build/linux-out/config-linux-6.12-riscv64-minbringup /repo/build/linux-build-hello-clean/.config
    else
      make -C /linux-src O=/repo/build/linux-build-hello-clean ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- allnoconfig
      /linux-src/scripts/kconfig/merge_config.sh -m /repo/build/linux-build-hello-clean/.config /repo/platform/linux_minbringup.fragment
    fi

    /linux-src/scripts/config --file /repo/build/linux-build-hello-clean/.config \
      -e BLK_DEV_INITRD \
      -e BINFMT_ELF \
      -e BINFMT_SCRIPT \
      --set-str INITRAMFS_SOURCE /repo/build/linux-user-init/initramfs.linux.list

    make -C /linux-src O=/repo/build/linux-build-hello-clean ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /linux-src O=/repo/build/linux-build-hello-clean ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$JOBS Image

    cp /repo/build/linux-build-hello-clean/arch/riscv/boot/Image /repo/build/linux-out/$IMAGE_NAME
    cp /repo/build/linux-build-hello-clean/vmlinux /repo/build/linux-out/vmlinux-linux-6.12-riscv64-hello-initramfs
    cp /repo/build/linux-build-hello-clean/System.map /repo/build/linux-out/System.map-linux-6.12-riscv64-hello-initramfs
    cp /repo/build/linux-build-hello-clean/.config /repo/build/linux-out/config-linux-6.12-riscv64-hello-initramfs
  "

echo "$LINUX_OUT/$IMAGE_NAME"
