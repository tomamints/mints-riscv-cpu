#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${LINUX_SRC_VOLUME:=}"
: "${LINUX_OUT:=$repo_root/build/linux-out}"
: "${KBUILD_OUT:=$repo_root/build/linux-build-busybox-clean}"
: "${KCONFIG_BASE:=$LINUX_OUT/config-linux-6.12-riscv64-minbringup}"
: "${IMAGE_NAME:=Image-linux-6.12-riscv64-busybox-initramfs}"
: "${INIT_SCRIPT_MODE:=default}"
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

busybox_bin="$repo_root/build/busybox-out/rv64imac-lp64/busybox"
initramfs_out="$repo_root/build/busybox-initramfs"
if [[ ! -x "$busybox_bin" ]]; then
  echo "missing BusyBox binary: $busybox_bin" >&2
  echo "run tools/build-rv64imac-busybox.sh first" >&2
  exit 1
fi

mkdir -p "$initramfs_out"
case "$INIT_SCRIPT_MODE" in
  default)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "BusyBox userspace on SystemVerilog RISC-V CPU"
echo "Type commands. Example: uname -a"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  console)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null

echo "BusyBox userspace on SystemVerilog RISC-V CPU"
echo "Type commands. Example: uname -a"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  debug)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

echo "[init] start"
mount -t proc proc /proc
echo "[init] mounted proc"
mount -t sysfs sysfs /sys
echo "[init] mounted sys"
mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "[init] mounted dev"
echo "BusyBox userspace on SystemVerilog RISC-V CPU"
echo "[init] after banner"
echo "Type commands. Example: uname -a"
echo "[init] before shell"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
echo "[init] shell returned"
INIT
    ;;
  short)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo A
echo B
echo C
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  fifo15)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "123456789012345"
echo "NEXT"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  fifo16)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "1234567890123456"
echo "NEXT"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  readloop)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "READLOOP"
while true; do
	echo "READ>"
	read line
	echo "INPUT=$line"
done
INIT
    ;;
  readloop-ttyS0)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "READLOOP-TTYS0"
while true; do
	echo "READ>"
	read line
	echo "INPUT=$line"
done
INIT
    ;;
  plainsh)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "PLAINSH"
exec /bin/sh -i
INIT
    ;;
  plainsh-ttyS0)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "PLAINSH-TTYS0"
exec /bin/sh -i
INIT
    ;;
  cttyhack-ttyS0)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CTTYHACK-TTYS0"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  oneecho)
    cat > "$initramfs_out/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

echo "BusyBox userspace on SystemVerilog RISC-V CPU
Type commands. Example: uname -a
[init] before shell"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  *)
    echo "unknown INIT_SCRIPT_MODE: $INIT_SCRIPT_MODE" >&2
    exit 1
    ;;
esac
chmod 0755 "$initramfs_out/init"

cat > "$initramfs_out/initramfs.list" <<LIST
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /etc 0755 0 0
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/ttyS0 0600 0 0 c 4 64
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
file /bin/busybox $busybox_bin 0755 0 0
slink /bin/sh busybox 0777 0 0
slink /bin/mount busybox 0777 0 0
slink /bin/uname busybox 0777 0 0
slink /bin/ls busybox 0777 0 0
slink /bin/cat busybox 0777 0 0
slink /bin/echo busybox 0777 0 0
slink /bin/pwd busybox 0777 0 0
slink /bin/dmesg busybox 0777 0 0
slink /bin/setsid busybox 0777 0 0
slink /bin/cttyhack busybox 0777 0 0
file /init $initramfs_out/init 0755 0 0
LIST

sed "s|$repo_root|/repo|g" \
  "$initramfs_out/initramfs.list" \
  > "$initramfs_out/initramfs.linux.list"

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
      --set-str INITRAMFS_SOURCE /repo/build/busybox-initramfs/initramfs.linux.list

    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig
    make -C /linux-src O=$kbuild_out_repo ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$JOBS Image

    cp $kbuild_out_repo/arch/riscv/boot/Image $linux_out_repo/$IMAGE_NAME
    cp $kbuild_out_repo/vmlinux $linux_out_repo/vmlinux-linux-6.12-riscv64-busybox-initramfs
    cp $kbuild_out_repo/System.map $linux_out_repo/System.map-linux-6.12-riscv64-busybox-initramfs
    cp $kbuild_out_repo/.config $linux_out_repo/config-linux-6.12-riscv64-busybox-initramfs
  "

echo "$LINUX_OUT/$IMAGE_NAME"
