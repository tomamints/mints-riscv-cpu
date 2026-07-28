#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${LINUX_SRC_VOLUME:=}"
: "${LINUX_OUT:=$repo_root/build/linux-out}"
: "${KBUILD_OUT:=$repo_root/build/linux-build-hello-clean}"
: "${KCONFIG_BASE:=$LINUX_OUT/config-linux-6.12-riscv64-minbringup}"
: "${IMAGE_NAME:=Image-linux-6.12-riscv64-hello-initramfs}"
: "${JOBS:=8}"

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

if [[ -z "$LINUX_SRC_VOLUME" && ! -d "$LINUX_SRC" ]]; then
  echo "missing Linux source: $LINUX_SRC" >&2
  exit 1
fi

"$repo_root/tools/build-hello-initramfs.sh" >/dev/null
sed "s|$repo_root|/repo|g" \
  "$repo_root/build/linux-user-init/initramfs.list" \
  > "$repo_root/build/linux-user-init/initramfs.linux.list"
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
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      bc bison flex make gcc gcc-riscv64-linux-gnu \
      libssl-dev libelf-dev dwarves ca-certificates >/tmp/apt.log

    mkdir -p $linux_out_repo $kbuild_out_repo

    if [[ -f $linux_out_repo/config-linux-6.12-riscv64-minbringup ]]; then
      cp $linux_out_repo/config-linux-6.12-riscv64-minbringup $kbuild_out_repo/.config
    elif [[ -f /repo/build/external/linux-out/config-linux-6.12-riscv64-minbringup ]]; then
      cp /repo/build/external/linux-out/config-linux-6.12-riscv64-minbringup $kbuild_out_repo/.config
    elif [[ -f /repo/build/linux-out/config-linux-6.12-riscv64-minbringup ]]; then
      cp /repo/build/linux-out/config-linux-6.12-riscv64-minbringup $kbuild_out_repo/.config
    else
      make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- allnoconfig
      /linux-src/scripts/kconfig/merge_config.sh -m $kbuild_out_repo/.config /repo/platform/linux_minbringup.fragment
    fi

    /linux-src/scripts/config --file $kbuild_out_repo/.config \
      -e BLK_DEV_INITRD \
      -e BINFMT_ELF \
      -e BINFMT_SCRIPT \
      --set-str INITRAMFS_SOURCE /repo/build/linux-user-init/initramfs.linux.list

    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$JOBS Image

    cp $kbuild_out_repo/arch/riscv/boot/Image $linux_out_repo/$IMAGE_NAME
    cp $kbuild_out_repo/vmlinux $linux_out_repo/vmlinux-${IMAGE_NAME#Image-}
    cp $kbuild_out_repo/System.map $linux_out_repo/System.map-${IMAGE_NAME#Image-}
    cp $kbuild_out_repo/.config $linux_out_repo/config-${IMAGE_NAME#Image-}
  "

echo "$LINUX_OUT/$IMAGE_NAME"
