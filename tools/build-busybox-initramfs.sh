#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${BUSYBOX_BIN:=$repo_root/build/busybox-out/rv64imac-lp64/busybox}"
: "${OUT_DIR:=$repo_root/build/busybox-initramfs}"
: "${INIT_SCRIPT_MODE:=default}"

case "$LINUX_SRC" in
  /*) ;;
  *) LINUX_SRC="$repo_root/$LINUX_SRC" ;;
esac

case "$BUSYBOX_BIN" in
  /*) ;;
  *) BUSYBOX_BIN="$repo_root/$BUSYBOX_BIN" ;;
esac

case "$OUT_DIR" in
  /*) ;;
  *) OUT_DIR="$repo_root/$OUT_DIR" ;;
esac

if [[ ! -f "$LINUX_SRC/usr/gen_init_cpio.c" ]]; then
  echo "missing Linux gen_init_cpio source: $LINUX_SRC/usr/gen_init_cpio.c" >&2
  exit 1
fi

if [[ ! -x "$BUSYBOX_BIN" ]]; then
  echo "missing BusyBox binary: $BUSYBOX_BIN" >&2
  echo "run tools/build-rv64imac-busybox.sh first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

cc "$LINUX_SRC/usr/gen_init_cpio.c" -o "$OUT_DIR/gen_init_cpio"

case "$INIT_SCRIPT_MODE" in
  default)
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "123456789012345"
echo "NEXT"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  fifo16)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "1234567890123456"
echo "NEXT"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  readloop)
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
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
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
exec </dev/console >/dev/console 2>&1

mount -t devtmpfs devtmpfs /dev 2>/dev/null
echo "PLAINSH"
exec /bin/sh -i
INIT
    ;;
  plainsh-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "PLAINSH-TTYS0"
exec /bin/sh -i
INIT
    ;;
  cttyhack-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CTTYHACK-TTYS0"
exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
INIT
    ;;
  oneecho)
    cat > "$OUT_DIR/init" <<'INIT'
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

chmod 0755 "$OUT_DIR/init"

cat > "$OUT_DIR/initramfs.list" <<LIST
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
file /bin/busybox $BUSYBOX_BIN 0755 0 0
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
file /init $OUT_DIR/init 0755 0 0
LIST

"$OUT_DIR/gen_init_cpio" "$OUT_DIR/initramfs.list" > "$OUT_DIR/initramfs.cpio"

echo "$OUT_DIR/initramfs.cpio"
