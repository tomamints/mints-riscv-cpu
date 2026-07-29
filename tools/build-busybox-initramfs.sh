#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${INIT_SCRIPT_MODE:=default}"
: "${LINUX_SRC:=$repo_root/build/linux-src}"
: "${BUSYBOX_BIN:=$repo_root/build/busybox-out/rv64imac-lp64/busybox}"
: "${OUT_DIR:=$repo_root/build/busybox-initramfs-$INIT_SCRIPT_MODE}"
: "${DUMP_INIT:=0}"
: "${SKIP_CPIO:=0}"

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

case "$BUSYBOX_BIN" in
  "$repo_root"/*) ;;
  *)
    echo "BUSYBOX_BIN must be inside repo: $BUSYBOX_BIN" >&2
    exit 1
    ;;
esac

case "$OUT_DIR" in
  "$repo_root"/*) ;;
  *)
    echo "OUT_DIR must be inside repo: $OUT_DIR" >&2
    exit 1
    ;;
esac

if [[ "$SKIP_CPIO" != "1" && ! -f "$LINUX_SRC/usr/gen_init_cpio.c" ]]; then
  echo "missing Linux gen_init_cpio source: $LINUX_SRC/usr/gen_init_cpio.c" >&2
  exit 1
fi

if [[ ! -x "$BUSYBOX_BIN" ]]; then
  echo "missing BusyBox binary: $BUSYBOX_BIN" >&2
  echo "run tools/build-rv64imac-busybox.sh first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ "$SKIP_CPIO" != "1" ]]; then
  cc "$LINUX_SRC/usr/gen_init_cpio.c" -o "$OUT_DIR/gen_init_cpio"
fi

case "$INIT_SCRIPT_MODE" in
  default)
    # Candidate default. Keep validating this against cmdloop/plainsh modes
    # until the interactive BusyBox shell path is stable.
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
/bin/busybox mkdir -p /tmp
mount -t tmpfs tmpfs /tmp 2>/dev/null
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
while :; do
	echo "READ>"
	line=
	IFS= read -r line
	read_status=$?
	echo "INPUT=[$line] status=$read_status"
done
INIT
    ;;
  readloop-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "READLOOP-TTYS0"
while :; do
	echo "READ>"
	line=
	IFS= read -r line
	read_status=$?
	echo "INPUT=[$line] status=$read_status"
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
  cttyhack-only-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CTTYHACK-ONLY-TTYS0"
exec /bin/busybox cttyhack /bin/sh -i
INIT
    ;;
  cmdloop-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh

/bin/busybox mount -t proc proc /proc || echo "WARN: proc mount failed: $?"
/bin/busybox mount -t sysfs sysfs /sys || echo "WARN: sysfs mount failed: $?"
/bin/busybox mount -t devtmpfs devtmpfs /dev || echo "WARN: devtmpfs mount failed: $?"

/bin/busybox mkdir -p /tmp
/bin/busybox mount -t tmpfs tmpfs /tmp || echo "WARN: tmpfs mount failed: $?"

exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CMDLOOP-TTYS0"
echo "MARK-A: before loop"

while :; do
	echo "MARK-B: before read"
	line=
	IFS= read -r line
	read_status=$?
	echo "MARK-C: read returned"
	echo "status=$read_status"
	echo "line=[$line]"

	case "$line" in
		"")
			echo "empty command"
			;;
		"echo OK")
			echo "OK"
			;;
		"echo hello")
			echo "hello"
			;;
		"pwd")
			/bin/busybox pwd
			echo "command-status=$?"
			;;
		"uname -a")
			/bin/busybox uname -a
			echo "command-status=$?"
			;;
		"ls /")
			/bin/busybox ls /
			echo "command-status=$?"
			;;
		"ls -l /bin")
			/bin/busybox ls -l /bin
			echo "command-status=$?"
			;;
		"cat /proc/cpuinfo")
			/bin/busybox cat /proc/cpuinfo
			echo "command-status=$?"
			;;
		"cat /proc/interrupts")
			/bin/busybox cat /proc/interrupts
			echo "command-status=$?"
			;;
		"filetest")
			/bin/busybox mkdir -p /tmp/test || {
				echo "mkdir failed: $?"
				continue
			}
			/bin/busybox sh -c 'echo hello > /tmp/test/message.txt' || {
				echo "write failed: $?"
				continue
			}
			/bin/busybox cat /tmp/test/message.txt
			/bin/busybox rm -f /tmp/test/message.txt
			/bin/busybox rmdir /tmp/test
			echo "filetest complete"
			;;
		"shell")
			echo "starting plain interactive shell"
			exec /bin/sh -i
			;;
		*)
			echo "unknown command: [$line]"
			;;
	esac
done
INIT
    ;;
  cmdloop-stty-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh

/bin/busybox mount -t proc proc /proc || echo "WARN: proc mount failed: $?"
/bin/busybox mount -t sysfs sysfs /sys || echo "WARN: sysfs mount failed: $?"
/bin/busybox mount -t devtmpfs devtmpfs /dev || echo "WARN: devtmpfs mount failed: $?"

/bin/busybox mkdir -p /tmp
/bin/busybox mount -t tmpfs tmpfs /tmp || echo "WARN: tmpfs mount failed: $?"

exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CMDLOOP-STTY-TTYS0"
echo "TERM-A: before stty -a"
/bin/busybox stty -F /dev/ttyS0 -a
echo "TERM-B: before stty sane"
/bin/busybox stty -F /dev/ttyS0 sane
echo "TERM-C: before canonical settings"
/bin/busybox stty -F /dev/ttyS0 icrnl icanon echo
echo "TERM-D: stty done"
echo "MARK-A: before loop"

while :; do
	echo "MARK-B: before read"
	line=
	IFS= read -r line
	read_status=$?
	echo "MARK-C: read returned"
	echo "status=$read_status"
	echo "line=[$line]"

	case "$line" in
		"")
			echo "empty command"
			;;
		"echo OK")
			echo "OK"
			;;
		"uname -a")
			/bin/busybox uname -a
			echo "command-status=$?"
			;;
		"ls /")
			/bin/busybox ls /
			echo "command-status=$?"
			;;
		"cat /proc/cpuinfo")
			/bin/busybox cat /proc/cpuinfo
			echo "command-status=$?"
			;;
		"cat /proc/interrupts")
			/bin/busybox cat /proc/interrupts
			echo "command-status=$?"
			;;
		"filetest")
			/bin/busybox mkdir -p /tmp/test || {
				echo "mkdir failed: $?"
				continue
			}
			/bin/busybox sh -c 'echo hello > /tmp/test/message.txt' || {
				echo "write failed: $?"
				continue
			}
			/bin/busybox cat /tmp/test/message.txt
			/bin/busybox rm -f /tmp/test/message.txt
			/bin/busybox rmdir /tmp/test
			echo "filetest complete"
			;;
		"shell")
			echo "starting plain interactive shell"
			exec /bin/sh -i
			;;
		*)
			echo "unknown command: [$line]"
			;;
	esac
done
INIT
    ;;
  setsid-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "SETSID-TTYS0"
exec /bin/busybox setsid /bin/sh -i
INIT
    ;;
  cmdloop-exec-ttyS0)
    cat > "$OUT_DIR/init" <<'INIT'
#!/bin/sh
/bin/busybox mount -t proc proc /proc || echo "WARN: proc mount failed: $?"
/bin/busybox mount -t sysfs sysfs /sys || echo "WARN: sysfs mount failed: $?"
/bin/busybox mount -t devtmpfs devtmpfs /dev || echo "WARN: devtmpfs mount failed: $?"
/bin/busybox mkdir -p /tmp
/bin/busybox mount -t tmpfs tmpfs /tmp || echo "WARN: tmpfs mount failed: $?"
exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "CMDLOOP-EXEC-TTYS0"
while :; do
	echo "cmd>"
	line=
	IFS= read -r line
	read_status=$?
	echo "read-status=$read_status line=[$line]"
	case "$line" in
		"")
			continue
			;;
		"echo OK")
			echo "OK"
			echo "status=0"
			;;
		"echo hello")
			echo "hello"
			echo "status=0"
			;;
		"pwd")
			/bin/busybox pwd
			echo "status=$?"
			;;
		"uname -a")
			/bin/busybox uname -a
			echo "status=$?"
			;;
		"ls /")
			/bin/busybox ls /
			echo "status=$?"
			;;
		"ls -l /bin")
			/bin/busybox ls -l /bin
			echo "status=$?"
			;;
		"cat /proc/cpuinfo")
			/bin/busybox cat /proc/cpuinfo
			echo "status=$?"
			;;
		"cat /proc/interrupts")
			/bin/busybox cat /proc/interrupts
			echo "status=$?"
			;;
		"filetest")
			/bin/busybox mkdir -p /tmp/test
			/bin/busybox sh -c 'echo hello > /tmp/test/message.txt'
			/bin/busybox cat /tmp/test/message.txt
			/bin/busybox rm /tmp/test/message.txt
			/bin/busybox rmdir /tmp/test
			echo "status=$?"
			;;
		"shell")
			echo "starting interactive shell"
			exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
			;;
		*)
			echo "fallback sh -c: $line"
			/bin/busybox sh -c "$line"
			echo "status=$?"
			;;
	esac
done
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

/bin/sh -n "$OUT_DIR/init"

if [[ "$DUMP_INIT" == "1" ]]; then
  echo "===== generated /init ====="
  sed -n '1,240p' "$OUT_DIR/init"
  echo "==========================="
fi

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
slink /bin/mkdir busybox 0777 0 0
slink /bin/rmdir busybox 0777 0 0
slink /bin/rm busybox 0777 0 0
slink /bin/cp busybox 0777 0 0
slink /bin/mv busybox 0777 0 0
slink /bin/ps busybox 0777 0 0
slink /bin/sleep busybox 0777 0 0
slink /bin/stty busybox 0777 0 0
slink /bin/printf busybox 0777 0 0
file /init $OUT_DIR/init 0755 0 0
LIST

repo_init="/repo/${OUT_DIR#"$repo_root"/}/init"
repo_busybox="/repo/${BUSYBOX_BIN#"$repo_root"/}"

sed \
  -e "s| $BUSYBOX_BIN | $repo_busybox |" \
  -e "s| $OUT_DIR/init | $repo_init |" \
  "$OUT_DIR/initramfs.list" > "$OUT_DIR/initramfs.linux.list"

if [[ "$SKIP_CPIO" != "1" ]]; then
  "$OUT_DIR/gen_init_cpio" "$OUT_DIR/initramfs.list" > "$OUT_DIR/initramfs.cpio"
fi

if [[ "$SKIP_CPIO" == "1" ]]; then
  echo "$OUT_DIR/initramfs.linux.list"
else
  echo "$OUT_DIR/initramfs.cpio"
fi
