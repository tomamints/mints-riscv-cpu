# Linux Bring-up Milestones

この文書は、自作 SystemVerilog RISC-V CPU 上で「Linuxが動いた」と判断する基準と、その後の確認項目を整理するためのものです。

## Goal Definition

このプロジェクトでは、単にLinux kernelのboot logが出るだけではなく、BusyBox shellから通常のコマンドを入力して結果が返る段階を、最初の「Linuxが動いた」基準にします。

合格条件:

```text
自作RISC-V CPU
  -> OpenSBI
  -> Linux kernel
  -> initramfs
  -> BusyBox /init
  -> 対話shell
  -> コマンド入力と結果表示
```

具体的には、shell promptから次のような操作ができることを確認します。

```sh
echo hello
pwd
uname -a
ls /
ls -l /bin
cat /proc/cpuinfo
cat /proc/interrupts
```

ここまで通れば、CPU、OpenSBI、Linux kernel、UART console、initramfs、U-mode userland、syscall、基本的なプロセス実行がつながったと判断できます。

## Current Position

すでに到達済み:

- OpenSBI `fw_jump.bin` が起動する
- Linux 6.12.yがS-modeで起動する
- Sv39を有効化したLinux kernelが実行継続する
- PLICがLinuxから認識される
- NS16550A互換UARTがearlycon / normal consoleとして認識される
- `rv64imac/lp64` soft-float static BusyBoxをinitramfsに入れられる
- Linuxが `/init` をPID 1として実行する
- `/dev/ttyS0` 直結の `readloop-ttyS0` で入力行が `INPUT=[...] status=0` と返る

直近の残り:

- default BusyBox `/init` で `/dev/ttyS0` + `setsid` + `cttyhack` の対話shellを安定させる
- shellから `uname -a` などの外部コマンドを実行する
- `/tmp` をtmpfsとしてmountし、書き込み可能な作業領域を用意する
- 対話shellの行編集で詰まる場合は、`cmdloop-ttyS0` で `read` + `/bin/sh -c` によりコマンド実行経路を先に確認する

## Initramfs Policy

bring-up用のdefault `/init` は次の方針です。

```sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /tmp
mount -t tmpfs tmpfs /tmp 2>/dev/null

exec </dev/ttyS0 >/dev/ttyS0 2>&1

echo "BusyBox userspace on SystemVerilog RISC-V CPU"
echo "Type commands. Example: uname -a"

exec /bin/busybox setsid /bin/busybox cttyhack /bin/sh
```

意図:

- `/dev/console` ではなく、Linuxが通常consoleとして登録した `/dev/ttyS0` を直接使う
- `setsid` で新しいsessionを作る
- `cttyhack` でshellにcontrolling ttyを与える
- `/tmp` はtmpfsにして、ファイル作成テストを安全に行う

対話shellの行編集やcontrolling ttyで詰まる場合は、bring-up用に次の簡易loopも使います。

```sh
INIT_SCRIPT_MODE=cmdloop-ttyS0
```

これは `/dev/ttyS0` から `IFS= read -r line` で1行受け取り、readの戻り値と入力行を表示したうえで既知コマンドだけを実行します。`readloop-ttyS0` で入力行が返ることは確認済みなので、対話shellのline editorを避けて、procfs、tmpfs、BusyBox applet実行を先に確認できます。`/bin/sh -c` によるfork/exec/waitも見る場合は `cmdloop-exec-ttyS0` を使います。

`cmdloop-ttyS0` の期待状態:

```text
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

ここで止まっている場合は、正常に入力待ちです。`echo OK` + Enterで次が出れば、この段階はPassです。

```text
MARK-C: read returned
status=0
line=[echo OK]
OK
MARK-B: before read
```

比較用のmode:

- `plainsh-ttyS0`: `/dev/ttyS0` 直結で `/bin/sh -i`
- `setsid-ttyS0`: `/dev/ttyS0` 直結で `setsid + /bin/sh -i`
- `cttyhack-only-ttyS0`: `/dev/ttyS0` 直結で `cttyhack + /bin/sh -i`
- `cttyhack-ttyS0`: `/dev/ttyS0` 直結で `setsid + cttyhack + /bin/sh`
- `cmdloop-stty-ttyS0`: `stty -a`, `stty sane`, `icrnl icanon echo` でTTY状態を表示・固定してから `cmdloop-ttyS0` と同じread診断

`default` は最終候補ですが、現時点では検証中です。対話shellが安定するまでは、`cmdloop-ttyS0` で「入力行を受けて返信する」経路を先に合格させます。

## Milestone A: Kernel Boot

目的:

- OpenSBIからLinux kernelへhandoffできる
- Linux boot logがUARTから出る
- `/init` が実行される

確認済み:

- `Linux version 6.12...`
- SBI Base / Time / IPI / RFENCE検出
- `earlycon: uart8250`
- `riscv-plic`
- `ttyS0 at MMIO 0x10000000`
- `Run /init as init process`

状態:

- 達成済み

## Milestone B: Interactive Linux

目的:

- shell promptが出る
- キーボード入力がLinux userlandへ届く
- shell builtinと外部コマンドが実行できる

確認コマンド:

```sh
echo hello
pwd
uname -a
ls /
ls -l /bin
cat /proc/cpuinfo
cat /proc/interrupts
```

見る機能:

- UART RX/TX
- PLIC interrupt
- Linux 8250 driver
- TTY line discipline
- U-mode syscall
- ELF実行
- procfs

状態:

- 現在の主作業

## Milestone C: Basic File Operations

目的:

- Linuxらしいファイル操作ができる
- tmpfs上で作成、読み出し、削除ができる

確認コマンド:

```sh
mkdir -p /tmp/test
cd /tmp/test
pwd

echo "hello Linux" > message.txt
ls -l
cat message.txt

cp message.txt copy.txt
mv copy.txt renamed.txt
rm renamed.txt

cd /
rmdir /tmp/test
```

見る機能:

- VFS
- tmpfs
- path lookup
- file read/write
- directory create/remove
- user memory copy

状態:

- Milestone B後に確認

## Milestone D: Process / Scheduler

目的:

- 複数プロセス、wait、timer、schedulerを確認する

確認コマンド:

```sh
ps
sleep 1
echo before
sleep 1
echo after

sleep 10 &
ps
wait

sh -c 'echo child-ok'
```

見る機能:

- fork / vfork / clone
- execve
- wait
- timer interrupt
- scheduler
- signalの基本経路

状態:

- Milestone C後に確認

## Milestone E: Stability Loop

目的:

- 1回だけ偶然動いた状態ではなく、繰り返し実行で安定性を見る

確認コマンド:

```sh
i=0
while [ "$i" -lt 100 ]; do
	echo "$i"
	i=$((i + 1))
done
```

ファイル操作込み:

```sh
i=0
while [ "$i" -lt 100 ]; do
	echo "$i" > /tmp/value
	cat /tmp/value
	i=$((i + 1))
done
```

見る機能:

- 長時間命令実行
- interruptからの復帰
- context switch
- page fault / copy_to_user / copy_from_user
- UART TX interrupt
- メモリ一貫性

状態:

- Milestone D後に確認

## Milestone F: Normal Embedded Linux Shape

目的:

- bring-up用 `/init -> shell` から、通常の組み込みLinuxに近い構成へ進める

目標構成:

```text
Linux
  -> BusyBox init
  -> /etc/inittab
  -> getty ttyS0
  -> shell
```

利点:

- shell終了後にgettyが再起動する
- PID 1が子プロセスを回収する
- 起動処理を `/etc/init.d/rcS` に分離できる
- 複数サービスを管理しやすい

状態:

- 「Linuxが動いた」確認後に着手

## Milestone G: Persistent Storage

目的:

- 再起動後も残るrootfsまたはmount可能なblock deviceを用意する

候補:

- RAM disk
- simple block device
- virtio-blk互換device
- SD card controller
- SPI flash

確認例:

```sh
mount /dev/... /mnt
echo hello > /mnt/file
sync
reboot
cat /mnt/file
```

状態:

- 後続フェーズ

## Regression Direction

Milestone B/Cが通ったら、手動操作だけで終わらせず、回帰テストとして残します。

最初の自動化候補:

- Linux起動ログに `Run /init as init process` が出る
- BusyBox bannerが出る
- `echo hello` に対して `hello` が返る
- `uname -a` が返る
- `/tmp` でファイル作成、`cat`、削除ができる

これにより、今後RTLやデバイス実装を触ったときに、Linux userlandまでの経路が壊れていないかを確認できます。
