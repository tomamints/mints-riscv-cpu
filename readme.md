# MiNTs-CPU

`cpu.kanataso.net` の教材「Verylで作るCPU」を参考に、Veryl 実装を SystemVerilog で実装し直している RISC-V CPU です。このCPUの名前は **MiNTs-CPU** です。

DMA は教材由来ではなく、このリポジトリで独自に追加している実験的な機能です。

- 参考: https://cpu.kanataso.net/
- U-mode / CSR 章: https://cpu.kanataso.net/22-umode-csr.html

## Current Status

現状は、CPU 本体の移植実装と、独自 DMA の試作が混在している状態です。

`make build` による Verilator build は通ります。riscv-tests 由来のテスト結果は `Docs/TEST_STATUS.md` に整理しています。

## Implemented CPU Features

教材実装を SystemVerilog に移植している範囲として、以下が実装されています。

| Area | Status | Notes |
|---|---:|---|
| RV64I base instructions | Implemented | ALU, branch, jump, load/store |
| RV64M | Implemented | `MUL`, `DIV`, `REM`, `*W` 系 |
| RV64A | Implemented | LR/SC, AMO 系 |
| RVC | Implemented | `rvc_converter.sv` で 16-bit 命令を 32-bit 命令へ展開 |
| Pipeline | Implemented | IF/ID/EX/MEM/WB 相当、FIFO と stall/flush 制御 |
| MMIO | Implemented | RAM, ROM, debug I/O, ACLINT, PLIC, DMA, NS16550A最小UARTへ decode |
| CSR | Implemented | Machine/Supervisor/User 関連 CSR を部分実装 |
| Exceptions | WIP | illegal instruction, ECALL, EBREAK, misaligned access など |
| Interrupts | WIP | ACLINT の software/timer interrupt とPLICのexternal interruptを CSR unit に接続 |
| Privilege modes | WIP | M/S/U mode、trap delegation、`MRET`/`SRET` を部分実装 |
| PMP | WIP | 8 entries、TOR/NAPOT、data/fetch check。S-mode allow-all、禁止load/store/fetch fault、OpenSBI PMP domain経由のS-mode payload fetchを確認 |
| Sv39 | WIP | `satp.MODE=8`、3-level PTW、data/fetch translation、basic page faultを確認 |
| UART | WIP | `0x10000000` にNS16550A互換の最小TX/LSR/THRE interruptを追加。polling byte writeとPLIC経由IRQを確認 |
| PLIC | WIP | `0x0c000000` にSiFive PLIC互換寄せの最小実装を追加。32 sources、UART IRQ 10、M/S context、claim/completeを確認 |

## U-mode / CSR Support

`22-umode-csr.html` の内容を踏まえ、U-mode と CSR 周辺は以下のように実装されています。

- `PrivMode` として `M`, `S`, `U` を定義
- `mstatus.UXL`, `mstatus.SXL`, `MPP`, `SPP`, `MIE/MPIE`, `SIE/SPIE` を扱う
- CSR privilege violation を illegal instruction として扱う
- read-only CSR への write を illegal instruction として扱う
- `mcounteren` / `scounteren` による counter CSR アクセス制御
- `MRET` / `SRET` の privilege check
- ECALL の cause を現在 privilege mode に応じて調整
- trap 時に `mepc/mcause/mtval` または `sepc/scause/stval` を更新
- `medeleg` / `mideleg` による M/S trap delegation を部分実装

ただし、実装は U-mode 章の範囲だけではなく、S-mode 関連の CSR や trap delegation も入り始めています。そのため、現状は「U-mode 完了」というより、M/S/U privilege 周辺を段階的に移植している途中です。

## Original DMA Work

DMA は独自追加の MMIO peripheral です。目的は、CPU がメモリコピーに費やす命令実行を減らすため、CPU から MMIO register で DMA を設定し、RAM 間転送を行うことです。

現在の実装では、`src/dma.sv` が DMA slave/MMIO interface と RAM master interface を持っています。`src/top.sv` では DMA の RAM master が `ram_arbiter_cpu_prio` に接続され、CPU と DMA が RAM access を共有します。

現在サポートしている DMA 動作:

- MMIO register による `CTRL`, `STATUS`, `SRC`, `DST`, `LEN` の read/write
- `CTRL.start` による転送開始
- `STATUS.busy`, `STATUS.done`, `STATUS.err`
- 8-byte alignment check
- `LEN == 0` の即時完了
- RAM から read し、RAM へ write する 8-byte 単位コピー
- CPU 優先の RAM arbitration

未対応または注意点:

- DMA interrupt 出力は未実装
- byte/half/word 単位のコピーは未対応
- RAM 範囲外の `SRC` / `DST` check は未実装
- busy 中の `SRC` / `DST` / `LEN` write と追加 start は無視する
- `debug_dma.c` による基本的な RAM-to-RAM copy test は実行可能

## DMA Register Map

DMA の詳細仕様は `Docs/DMA.md` に整理しています。

現在の実装上の register map は `src/eei.sv` にある以下です。

| Register | Offset |
|---|---:|
| `CTRL` | `0x00` |
| `STATUS` | `0x08` |
| `SRC` | `0x10` |
| `DST` | `0x18` |
| `LEN` | `0x20` |

ソフトウェアやテストを書く場合は、`src/eei.sv` と `Docs/DMA.md` の register map を前提にしてください。

## Build

Verilator を使って build します。

```sh
make build
```

生成される simulator は以下です。

```text
obj_dir/sim
```

古い Verilator 生成物が残っている場合は、先に clean します。

```sh
make clean
make build
```

## Run

`Makefile` では以下の変数を使って simulation input を指定します。

```sh
make run ROM=path/to/rom.hex RAM=path/to/ram.hex CYCLES=1000
```

default は以下です。

```text
ROM=core/test/hex/sample_ecall.hex
RAM=$(ROM)
CYCLES=20
```

## Tests

`core/test/share` にある riscv-tests 由来の ELF / hex を、`tools/run_riscv_tests.py` 経由で実行できます。

単体テスト:

```sh
make test TEST=rv32ui-p-add
```

smoke test:

```sh
make test-smoke
```

suite 実行:

```sh
make test-suite SUITE=rv32ui-p
```

よく使う suite には alias があります。

```sh
make test-rv32ui
make test-rv32um
make test-rv32ua
make test-rv32uc
make test-rv32mi
make test-rv32si
make test-rv64ui
make test-rv64um
make test-rv64ua
make test-rv64uc
make test-rv64mi
make test-rv64si
```

現時点で確認した結果:

```text
make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full
rv32ui-p 42 / 42
rv32um-p  8 / 8
rv32ua-p 10 / 10
rv32uc-p  1 / 1
rv32mi-p 16 / 16
rv32si-p  6 / 6
rv64ui-p 54 / 54
rv64um-p 13 / 13
rv64ua-p 19 / 19
rv64uc-p  1 / 1
rv64mi-p 17 / 17
rv64si-p  7 / 7
```

より広い suite の結果は `Docs/TEST_STATUS.md` を参照してください。注意点として、`F`, `D`, `Zb*`, `Zfh` 系は現状の実装から正式サポートとは扱っていません。

## Platform DTB

Linux/OpenSBI bring-up向けの最小DTSは `platform/riscv_cpu.dts` です。現RTLのaddress mapに合わせて、RAMを `0x80000000` から128MiB、UARTを `0x10000000` に置いています。

```sh
make dtb
make test-linux-bootargs
```

生成物は `build/platform/riscv_cpu.dtb` です。現在はPLIC nodeとUART IRQ 10もDTBに記述しています。Linux earlyconは引き続き `earlycon=uart8250,mmio,0x10000000` のpolling出力で確認し、通常consoleはPLIC/UART interrupt経路の確認後に進めます。

`test-linux-bootargs` は、Linux boot ABIに合わせた最小bootromを使い、`a0=hartid=0`、`a1=0x87f00000` をRAM payloadへ渡せることを確認します。DTBはRAM image内の `0x87f00000` に配置します。

OpenSBIを試す場合は、repo外で用意した `fw_jump.bin` を指定します。

```sh
make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin
```

現在はOpenSBI v1.3.1 `FW_JUMP` でplatform情報表示と、`0x80200000` に置いた小さいS-mode payloadへのhandoffまで確認済みです。OpenSBIからは `uart8250` console、`aclint-mswi` IPI、`aclint-mtimer @ 50000000Hz` timer、`PMP Count = 8`、`Next Address = 0x80200000`、`Next Arg1 = 0x87f00000`、`Next Mode = S-mode` まで見えています。

OpenSBI handoff確認用の最小payloadは以下で実行できます。

```sh
make test-opensbi-payload OPENSBI_BIN=/path/to/fw_jump.bin
```

OpenSBI起動までに修正した内容と調査メモは `Docs/OPENSBI_BRINGUP.md` にまとめています。

Linux Imageも同時に置く場合は、`0x80200000` に配置します。

```sh
make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=/path/to/Image
```

現在の確認済みLinux Image:

```text
build/external/linux-out/Image-linux-6.12-riscv64
build/external/linux-out/Image-linux-6.12-riscv64-minbringup
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-initramfs
```

例:

```sh
make run-opensbi \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-minbringup \
  OPENSBI_CYCLES=0
```

`Image-linux-6.12-riscv64` は最初に試したdefconfig寄りのImageです。Linux bootは進みますが、raid6、jitterentropy、SCSI、USB、mediaなど余分な初期化が多く、Verilatorでは非常に遅くなります。

`Image-linux-6.12-riscv64-minbringup` は `allnoconfig` ベースのbring-up用Imageです。設定の意図は `platform/linux_minbringup.fragment` に残しています。SBI、DTB、timer、PLIC、8250 UART console、proc/sysfs/devtmpfs、ELF実行に必要なものを残し、Linux起動確認に不要な重いsubsystemを削っています。

このImageでは以下を確認済みです。

```text
riscv-plic: interrupt-controller@c000000: mapped 32 interrupts with 1 handlers for 2 contexts.
Serial: 8250/16550 driver, 4 ports, IRQ sharing disabled
10000000.serial: ttyS0 at MMIO 0x10000000 (irq = 1, base_baud = 230400) is a 16550A
printk: legacy console [ttyS0] enabled
Kernel panic - not syncing: VFS: Unable to mount root fs on "" or unknown-block(0,0)
```

最後のpanicはrootfs/initramfs未指定による期待結果です。

BusyBox initramfs投入も確認済みです。既製のBusyBoxではなく、現在のCPUに合わせた `rv64imac/lp64` soft-float static BusyBoxを作っています。

- `/init` は `#!/bin/sh` スクリプトなので、Linux configに `CONFIG_BINFMT_SCRIPT=y` が必要です。
- 既製の `riscv64/busybox:musl` とUbuntu cross toolchainで作ったBusyBoxは `double-float ABI` でした。現在のCPU/DTBは `rv64imac` でF/D拡張を公開していないため、このBusyBoxを実行するとU-modeでillegal instructionになります。
- `tools/build-rv64imac-musl-toolchain.sh` で `rv64imac/lp64` のmusl Linux userland toolchainを作り、`tools/build-rv64imac-busybox.sh` でstatic BusyBoxを作る構成にしています。
- macOSのcase-insensitive filesystemではLinux sourceの `Documentation/Kbuild` と `Documentation/kbuild/` が衝突するため、Linux sourceはDocker volume `linux-6.12-src` に置く運用を推奨します。

補助スクリプト:

```sh
tools/build-rv64imac-musl-toolchain.sh
tools/build-rv64imac-busybox.sh
tools/build-linux-busybox-initramfs-image.sh
```

Linux bring-upの達成条件と、対話shell後に確認するコマンド群は `Docs/LINUX_MILESTONES.md` に整理しています。このプロジェクトでは、Linux kernel logが出るだけではなく、BusyBox shellから `uname -a`, `ls`, `cat`, `mkdir` などを実行できる段階を最初の「Linuxが動いた」基準にします。

`tools/build-rv64imac-musl-toolchain.sh` は `build/riscv-musl-lp64` に `riscv64-unknown-linux-musl-gcc` を作ります。`tools/build-rv64imac-busybox.sh` はそのtoolchainでstatic BusyBoxを作ります。`tools/build-linux-busybox-initramfs-image.sh` はBusyBox入りinitramfsをbuilt-inしたLinux Imageを作ります。

BusyBox Image作成:

```sh
INIT_SCRIPT_MODE=cmdloop-ttyS0 \
LINUX_SRC_VOLUME=linux-6.12-src \
LINUX_OUT=build/external/linux-out \
JOBS=4 \
tools/build-linux-busybox-initramfs-image.sh
```

BusyBox起動:

```sh
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-initramfs \
  OPENSBI_CYCLES=0
```

現在は以下まで確認済みです。

```text
Run /init as init process
BusyBox userspace on MiNTs-CPU
Type commands. Example: uname -a
/bin/sh: can't access tty; job control turned off
~ #
```

`can't access tty; job control turned off` は、`/init` が制御TTYをまだ整備していない場合に出ます。`readloop-ttyS0` では `/dev/ttyS0` 直結で入力行が `INPUT=[...] status=0` と返ることを確認しているため、UART RX / PLIC / Linux 8250 driver / `/dev/ttyS0` read は通っています。現在のBusyBox initramfsのdefaultは、`/dev/console` ではなく `/dev/ttyS0` をstdin/stdout/stderrへ接続し、`setsid + cttyhack + /bin/sh` で制御TTYを取る構成です。

Linux通常console移行後に `BusyBox userspac` で16文字だけ出て止まる問題がありました。これは16550の16-byte FIFO境界で、TX empty interruptが再発行されていないことが原因でした。`src/uart_ns16550.sv` ではTHR write後に1サイクルだけ送信中扱いにし、その次のサイクルで `IER[1]` が有効なら `tx_irq_pending` を再度立てるようにしています。PLIC側はclaim済み割り込みを `in_service` として持ち、claimからcompleteまで同じlevel IRQを再pendingしない最小gatewayモデルにしています。入力側はVerilator host terminalのcanonical modeだけを切り、1文字ずつsimulatorへ渡します。host terminal echoは残しているため、入力文字はhost側でも見えます。UART状態の追跡には `SIM_EXTRA_ARGS='+TRACE_UART'` を使えます。入力デバッグ時は `SIM_EXTRA_ARGS='+TRACE_RXUART'` を使うと、hostから取り込んだbyteを `[UART RX]`、Linuxが見る受信状態を `[UART IIR] value=04` / `[UART LSR]`、LinuxがRBRから読んだbyteを `[UART RBR]` としてTXログを抑えて確認できます。TX完了待ちの調査では `SIM_EXTRA_ARGS='+TRACE_TXUART'` を使うと、THR write、IER変更、THRE interruptを示す `IIR=02`、`[UART TX EMPTY]`、TX中のLSRを中心に確認できます。PLIC側は `+TRACE_IRQ10PLIC` でUART IRQ 10のsource/pending/in_service/seip変化とS-context claim/completeだけを確認できます。`+TRACE_UART_RX` は `+TRACE_UART` に前方一致してしまうため使いません。

BusyBox initramfsの `/init` は `INIT_SCRIPT_MODE` で切り替えられます。`/init` の生成元は `tools/build-busybox-initramfs.sh` に集約しており、Linux Image生成側の `tools/build-linux-busybox-initramfs-image.sh` はこのスクリプトを呼び出すだけです。

`OUT_DIR` と `KBUILD_OUT` はmodeごとに分かれます。`IMAGE_NAME` を指定しない場合も、`Image-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs` になります。これで `cmdloop-ttyS0`、`plainsh-ttyS0`、`cttyhack-ttyS0` などの成果物を上書きせずに比較できます。

```sh
INIT_SCRIPT_MODE=default  # candidate: ttyS0 + setsid + cttyhack。対話shell経路は検証中
INIT_SCRIPT_MODE=short    # echo A/B/C のあと shell
INIT_SCRIPT_MODE=fifo15   # 15文字+改行、NEXT、shell
INIT_SCRIPT_MODE=fifo16   # 16文字+改行、NEXT、shell
INIT_SCRIPT_MODE=console  # 古い /dev/console 経由の比較用
INIT_SCRIPT_MODE=readloop # shell script の read builtin で入力行を確認
INIT_SCRIPT_MODE=plainsh  # cttyhackを使わず /bin/sh -i
INIT_SCRIPT_MODE=readloop-ttyS0 # /dev/ttyS0 直結で read builtin を確認
INIT_SCRIPT_MODE=plainsh-ttyS0  # /dev/ttyS0 直結で /bin/sh -i
INIT_SCRIPT_MODE=cttyhack-ttyS0 # /dev/ttyS0 直結で setsid + cttyhack + /bin/sh
INIT_SCRIPT_MODE=cttyhack-only-ttyS0 # /dev/ttyS0 直結で cttyhack + /bin/sh -i
INIT_SCRIPT_MODE=setsid-ttyS0   # /dev/ttyS0 直結で setsid + /bin/sh -i
INIT_SCRIPT_MODE=cmdloop-ttyS0  # read戻り値と既知コマンドを確認する診断loop
INIT_SCRIPT_MODE=cmdloop-stty-ttyS0 # sttyでTTY状態を表示・固定してからcmdloop
INIT_SCRIPT_MODE=cmdloop-exec-ttyS0 # read後に /bin/sh -c も試す診断loop
INIT_SCRIPT_MODE=debug    # /init の到達点を細かく表示
```

`cmdloop-ttyS0` の期待ログは次です。

```text
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

ここで止まるのは正常な入力待ちです。`echo OK` + Enter 後に `MARK-C: read returned`、`line=[echo OK]`、`OK`、次の `MARK-B: before read` が出れば、TTY input、shell builtin `read`、script内分岐、stdoutへの返信が通っています。

`echo OK` + EnterでUARTの `[UART RX]` と `[UART RBR]` に `0a` まで出るのに `MARK-C` が出ない場合は、Linux 8250 driverがRBRから読んだ後、TTY line disciplineまたはread待ちtaskのwake-upで止まっています。その場合は `cmdloop-stty-ttyS0` を使い、`stty -a`、`stty sane`、`icrnl icanon echo` のどこまで進むかを確認します。

RX調査時の期待ログは次です。

```text
[UART RX] char=65
[UART IIR] value=04
[UART LSR] value=61
[UART RBR] char=65
```

Enterでも `[UART RX] char=0a` と `[UART RBR] char=0a` まで出るのに `MARK-C` が出ない場合、UART byte消失ではなく、LinuxのTTY/read wake-up以降を疑います。

`fifo15` で `NEXT` と `~ #` が表示される場合、16-byte FIFO境界付近のTX再割り込みと `/init` からshell起動までは通っています。そこで入力しても反応しない場合は、`readloop-ttyS0`、`cmdloop-ttyS0`、`cmdloop-stty-ttyS0` で `/dev/ttyS0` を直接stdin/stdoutにして、TTY line discipline / shell stdin / interactive shell起動方式を切り分けます。

生成されたinitramfs用 `/init` の中身をビルド時に確認したい場合は、`DUMP_INIT=1` を付けます。

```sh
DUMP_INIT=1 INIT_SCRIPT_MODE=cmdloop-ttyS0 \
  tools/build-linux-busybox-initramfs-image.sh
```

BusyBoxの前段として、libcなしの最小 `/init` も用意しています。`platform/linux_user_init.S` は `write(2)` と `exit(2)` だけを直接呼ぶユーザーアプリで、LinuxがU-modeのPID 1を起動し、syscall writeでconsoleへ出力できることを確認するためのものです。`platform/linux_user_init_read.S` はさらに `/dev/console` から1文字 `read(2)` し、読み取った文字を表示してからU-modeで待機します。`platform/linux_user_init_line.S` は `/dev/console` に `read(fd, buf, 64)` を発行し、Enterで1行が確定してから `read line: ...` と表示されるかを見るTTY line discipline確認用です。

入力版のLinux Imageは次の流れで作ります。

```sh
INIT_SRC=platform/linux_user_init_read.S \
  LINUX_SRC_VOLUME=linux-6.12-src \
  LINUX_OUT=build/external/linux-out \
  KBUILD_OUT=build/linux-build-hello-clean \
  tools/build-linux-hello-initramfs-image.sh
```

TTY line discipline確認用:

```sh
INIT_SRC=platform/linux_user_init_line.S \
  IMAGE_NAME=Image-linux-6.12-riscv64-line-initramfs \
  LINUX_SRC_VOLUME=linux-6.12-src \
  LINUX_OUT=build/external/linux-out \
  KBUILD_OUT=build/linux-build-line-clean \
  JOBS=4 \
  tools/build-linux-hello-initramfs-image.sh
```

起動時は入力対応simulatorを使います。

```sh
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-hello-initramfs \
  OPENSBI_CYCLES=0
```

Linux boot logは、Linuxから見ると `0x10000000` のNS16550A互換UARTへ出ています。シミュレーション上では `uart_ns16550.sv` からVerilatorの標準出力へ流すため、`make run-opensbi` を実行しているterminalに表示されます。

`OPENSBI_CYCLES` はシミュレータの最大実行サイクル数です。`0` は無制限実行用です。Linux起動の長時間確認では `SIM_EXTRA_ARGS` なしを推奨します。`+TRACE_PIPE` は大量のprintfを出すため、原因追跡時だけ使います。

Linuxログの `[    0.004184]` はLinuxが認識している起動後時刻で、`0.004184` 秒、つまり `4.184ms` です。一方、`[PIPE] cycle=...` はCPUクロック数です。DTB上のCPU clockを50MHzとして見るなら `cycle / 50,000,000` 秒に相当します。ただしVerilator実行時間はFPGA実時間よりかなり遅くなります。

現在のRTLでは `mtime` が毎CPUクロック増えるため、DTBの `timebase-frequency` も50MHzに合わせています。これが1MHzのままだと、Linux/OpenSBIからはtimerが50倍速に見え、timer interruptが過剰に発生する可能性があります。

Linux boot中に `string_get_size()` で止まって見えた問題は、mul/div handshakeが古い `rvalid/result` を現在のMUL命令の結果として扱っていたことが原因でした。`src/core.sv` で `exs_muldiv_accept` を明示し、requestがacceptされた命令だけが `rvalid/result` を受け取るように修正しています。確認は `make c-test C_TEST=muldiv_string_size CYCLES=200000` と `make test-rv64um` です。

### Custom C Tests

`core/test/*.c` は、RISC-V cross compiler で ELF / binary / hex を生成して simulator で実行できます。default の compile option は compressed instruction を避けつつ CSR 命令を許可するため `-march=rv64ima_zicsr` です。

debug output:

```sh
make test-output
```

`debug_output.c` は debug MMIO に `Hello,world!\n` を書き、最後に success を通知します。

debug input:

```sh
make test-input INPUT_TEXT=A
make test-input-interactive
```

`debug_input.c` は `ENABLE_DEBUG_INPUT` 付き simulator を `obj_dir_input/sim` に build し、stdin から受け取った文字を 1 増やして debug MMIO へ返します。`INPUT_TEXT=A` の場合は `B` が出ます。対話入力したい場合は `make test-input-interactive` を使います。この target は cycle limit なしで動くため、終了は `Ctrl-C` です。

DMA test:

```sh
make test-dma
```

`debug_dma.c` は DMA register を MMIO 経由で設定し、RAM-to-RAM copy を検証します。現在は `DMA test OK` と success まで到達することを確認済みです。

UART polling output:

```sh
make test-uart
make test-uart-input INPUT_TEXT=Z
make test-uart-regs
make test-uart-tx-irq
make test-uart-tx-seip
make test-uart-rx-seip INPUT_TEXT=Z
```

`uart_output.c` は NS16550A 互換UARTの `LSR` をpollingし、`THR` へbyte writeします。現在のUART baseは `0x10000000`、byte-spaced registerで、`LSR[5]=THRE` と `LSR[6]=TEMT` を常に1として返します。このテストで `A` と success まで到達することを確認済みです。

`uart_input.c` は `ENABLE_DEBUG_INPUT` 付き simulatorを使い、Verilator stdinから来た1文字をUARTの `RBR` で読み、同じ文字を `THR` へechoします。`INPUT_TEXT=Z` で `Z` と success まで到達することを確認済みです。RTL上は `LSR[0]=DR`、`IER[0]`、`IIR=0x04` の最小RX interrupt経路も持っています。

`uart_regs.c` は `IER/MCR/SCR/LCR` の保持、`LCR.DLAB=1` 時の `DLL/DLM` 切り替え、`IIR=0x01`、`MSR=0`、`LSR.THRE/TEMT=1` を確認します。Linux earlyconやOpenSBIのUART初期化で触る可能性がある最小レジスタ群のbring-up確認です。

`uart_tx_irq.c` は `IER[1]` 有効化で初回THRE interruptが来ることに加えて、`THR` へbyte writeした後にTHRE interruptが再発火することを確認します。Linux 8250 driverがUART送信を継続する時に近い経路です。

`uart_tx_seip.c` は同じTX interrupt再発火をS-mode PLIC contextで確認します。Linux通常consoleはS-mode側でUART interruptを受けるため、`uart_tx_irq.c` よりLinuxに近い確認です。

`uart_rx_seip.c` は `ENABLE_DEBUG_INPUT` 付きsimulatorでstdinから `Z` を受け取り、UART RX interruptがPLIC S-context経由でS-mode external interruptへ届くことを確認します。Enter入力でLinuxのUART handlerが起きるかを切り分けるためのテストです。

PLIC / UART interrupt:

```sh
make c-test C_TEST=plic_uart_irq CYCLES=200000
make c-test C_TEST=plic_seip CYCLES=300000
```

`plic_uart_irq.c` は `0x0c000000` のPLICでUART IRQ 10のpriority/enable/thresholdを設定し、UART `IER[1]` でTHRE interruptを発生させます。PLIC `claim` が10を返し、CPU側では `mip.MEIP` によりM-mode external interrupt `mcause=0x800000000000000b` へ入ることを確認します。

`plic_seip.c` はM-modeでPMP allow-allと`mideleg.SEIP`を設定してS-modeへ入り、PLIC S-context経由でUART IRQ 10をclaimします。CPU側では `mip.SEIP` によりS-mode external interrupt `scause=0x8000000000000009` へ入ることを確認します。

ACLINT interrupt tests:

```sh
make test-mswi
make test-mtime
```

`mswi.c` は machine software interrupt、`mtime.c` は machine timer interrupt を発生させ、handler 到達時に success を通知します。どちらも現在 pass します。

OS2 minimum port:

```sh
make test-os2-min
make test-os2-min-input INPUT_TEXT=Z
make test-os2-min-strap
make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=300000
make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_USER OS2_MIN_NAME=kernel_user CYCLES=120000
make test-os2-min-sv39
```

`core/test/os2_min/` は `/Users/shiraitouma/OS2` を参考に、このCPUで最初に動かすために最小化したCPU検証用環境です。過去のOS2はRV32/QEMU virt/OpenSBI前提の練習用実装なので、今後のOSはRV64/Sv39/独自SoC前提で新規に育てます。現時点では SBI、PMP、timer、最小U-mode entry/ecall、Sv39 data-side identity mapping、fetch-side identity mapping、SUM/MXRの基本permissionを小さく確認しています。virtio-blk、本格的なU-mode process管理はまだ戻していません。

`os2_min` の生成物 `.elf` / `.bin` / `.bin.hex` は `build/os2_min/` に出力します。`core/test/os2_min/` にはソース、ヘッダ、リンカスクリプトだけを置く方針です。

通常のCテスト生成物は `build/test/c_tests/`、bootrom生成物は `build/test/` に出力します。`core/test/` 直下にはテストソースとスクリプトだけを置く方針です。

この最小移植版は今後RVA23方向へ進める前段として、RV64 kernel前提に寄せています。`size_t` / `paddr_t` / `vaddr_t` / trap frame / CSR helper は64-bit幅に整理し、paging定義はSV32ではなくSV39を戻す前提にしています。

`make test-os2-min` は入力不要の統合テストです。M-mode boot code でPMP NAPOT allow-allを設定し、`mstatus.MPP=S` と `mepc=supervisor_main` を設定してS-modeへ入ります。その後、S-modeからSBI debug console putchar、SBI TIME `set_timer` を順に確認します。timer testでは M-modeが `mcounteren.TIME` を許可したうえで、S-mode が `time` CSR から絶対時刻を読み、M-mode firmware が ACLINT `mtimecmp` を設定します。その後 `MTIP -> M-mode trap handler -> STIP注入 -> S-mode stvec` の順に進み、S-mode timer interruptとして3回受け、`sip.STIP` clear、`sret` 復帰、次回timer再設定を確認します。

`make test-os2-min-input INPUT_TEXT=Z` は入力ありのSBIテストです。S-modeからSBI debug console getcharを呼び、入力文字を取得してdebug console putcharで出力します。

`make test-os2-min-strap` は S-mode `ecall` を `stvec` で受けるテストです。`medeleg[9]` で S-mode ecall を S-mode trap へ委譲し、handler で `sepc += 4` して `sret` で元のS-mode処理へ戻れることを確認します。

`OS2_MIN_PMP` は PMP access fault のテストです。M-modeでPMP entry1に `pmp_protected_word` の8byteだけTOR禁止領域を作り、entry2をNAPOT allow-allにします。その後S-modeから禁止wordをload/storeし、loadでは `scause=5`、storeでは `scause=7`、どちらも `stval=fault address` でS-mode trapへ入り、handlerで `sepc += 4` して復帰できることを確認します。さらにM-mode SBIで保護wordを読み直し、禁止storeがRAMを書き換えていないことも確認します。fetch側は、`pmp_protected_exec_target` を `X=1/R=0/W=0` にした場合は実行でき、`R=1/W=1/X=0` にした場合は `scause=1`、`stval=fetch address` でS-mode trapへ入ることを確認します。さらに32-bit命令を4byte境界+2に置き、命令後半2byteだけがX禁止領域に入る場合もinstruction access faultになることを確認します。

`OS2_MIN_USER` は最小U-modeテストです。S-modeで `stvec`、`medeleg[8]`、`sstatus.SPP=U`、`sepc=user_entry` を設定して `sret` し、U-modeへ入ります。U-mode側は1回目の `ecall` でS-mode trapへ入り、handlerが `a0=0x5678` と `sepc += 4` を設定してU-modeへ戻します。2回目の `ecall` はexit syscallとして扱い、S-mode handler側で `test success` を出します。

`make test-os2-min-sv39` は最小Sv39テストです。S-modeで3段page tableを作り、`satp.MODE=8` とroot PPNを設定します。CPU側は `sv39_ptw.sv` に分離したpage table walkerをdata-side load/storeとinstruction fetchの両方から使います。TLBはまだありませんが、`satp` CSR access と `sfence.vma` はfetchをflushし、次PCから取り直します。先頭256KiBのRAMとdebug MMIO 1ページを4KiB leaf PTEでidentity mapし、S-modeのload/store/fetchがVA->PA変換後に成功すること、2MiB L1 / 1GiB L2 superpage aliasでloadできること、未mapの `0x60000000` loadが `scause=13`、`stval=0x60000000` のload page faultになることを確認します。加えて、S-modeからUページへのloadが `SUM=0` ではfault、`SUM=1` では成功すること、execute-onlyページへのloadが `MXR=0` ではfault、`MXR=1` では成功すること、`A=0` load、`D=0` store、`W=0` storeがpage faultになること、root page table A/Bの `satp.PPN` を切り替えると同じVAが別PAを読むこと、`X=0` ページへのfetchが `scause=12` のinstruction page faultになることも確認します。

`sv39_ptw.sv` は architectural な `scause` とは別に `Sv39Fault` で内部fault理由も保持します。これはIOMMU側の `ptw_fault_e` と同じ位置づけで、波形や `+TRACE_SV39` でPTE invalid、W without R、reserved bit、permission、A/D不足、superpage misalignmentなどを切り分けるための情報です。A/D bitは現時点ではhardware updateせず、Svade相当のfault方式として扱います。PTW中のPTE読み出し自体が失敗した場合はpage faultではなく、元のアクセス種別に応じてinstruction/load/store access faultへ分類します。

今後の実装方針は `Docs/ROADMAP.md` に、機能ごとの進捗と次タスクは `Docs/TASK_STATUS.md` に整理しています。RVA23方向の棚卸しは `Docs/RVA23_CHECKLIST.md` に分けています。

Linux起動を大目標にするため、U-mode syscallは最小確認で一旦区切っています。Linux 6.12.y ImageはOpenSBI経由で起動し、earlyconで `Linux version 6.12.97`、SBI extension検出、memory init、SLUB、RCU、`riscv-intc`、clocksource、`sched_clock`、devtmpfs、pinctrl、DMA pool、HugeTLB、raid6 initまで出力できています。PLIC付きDTBでのOpenSBI platform認識とS-mode `SEIP` の小さいテストは確認済みです。次フェーズはLinux通常console登録、最小initramfsです。補助タスクとして、PTWメモリエラー発生源、TLB方針、UART RX/FIFOが残っています。

trace run:

```sh
make trace-output
make trace-dma
gtkwave sim.vcd
```

`obj_dir_trace/sim` を使って `sim.vcd` を生成します。

主な C test 変数:

```text
RISCV_PREFIX=/Users/shiraitouma/riscv/bin/riscv64-unknown-elf-
RISCV_CFLAGS=-march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles
DBG_ADDR=0x40000000
C_TEST=debug_output
INPUT_TEXT=A
```

主な変数:

```text
TEST=rv32ui-p-simple
SUITE=rv32ui-p
TEST_DIR=core/test/share
BOOTROM=build/test/bootrom.hex
TEST_OUT=results
TEST_TIMEOUT=10
RAM_BASE=0x80000000
TEST_RUNNER=tools/run_riscv_tests.py
```

## Repository Notes

- `boost_1_88_0/`, `whisper/`, `.DS_Store`, `obj_dir/`, `obj_dir_input/` は Git 管理対象外です。
- `Docs/DMA.md` は DMA の現在仕様です。
- 現状の README は、実装の現状を説明するためのものであり、RISC-V 仕様適合性を保証するものではありません。


## Execute Codes
export OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
export LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs

make run-opensbi-input \
OPENSBI_CYCLES=0 \
SIM_EXTRA_ARGS="+TRACE_HEARTBEAT"



obj_dir_input/sim \
  build/platform/bootrom_linux.hex \
  build/smoke/smoke_ram.hex \
  1000 \
  +TRACE_RETIRE \
  > build/smoke/rtl_mem.log 2>&1
