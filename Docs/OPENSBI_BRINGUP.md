# OpenSBI Bring-up Notes

Last updated: 2026-08-13

この文書は、OpenSBI v1.3.1 `FW_JUMP` のUART banner表示、OpenSBIからS-mode payloadへ到達するために行った変更、Linux Image投入の現在地を残すためのメモです。

現在確認できている到達点:

```text
Boot ROM
  -> OpenSBI at 0x80000000
  -> DTB at 0x87f00000
  -> UART banner output
  -> Next Address 0x80200000, Next Mode S-mode
  -> S-mode payload or Linux Image at 0x80200000
```

OpenSBIログ上では、以下まで確認済みです。

```text
Platform Console Device   : uart8250
Domain0 Next Address      : 0x0000000080200000
Domain0 Next Arg1         : 0x0000000087f00000
Domain0 Next Mode         : S-mode
Boot HART Base ISA        : rv64imac
Boot HART ISA Extensions  : time
Boot HART PMP Count       : 8
```

追加確認済み:

```text
Platform IPI Device       : aclint-mswi
Platform Timer Device     : aclint-mtimer
```

このため、OpenSBI generic platformから見たmachine software interrupt / machine timer interruptのplatform device認識は通っています。

PLICもLinux通常consoleへ進むために最小実装を追加しました。RTL単体では以下を確認済みです。

```text
UART IER[1]
  -> UART THRE interrupt
  -> PLIC source 10 pending
  -> PLIC claim returns 10
  -> mip.MEIP
  -> M-mode external interrupt
```

確認コマンド:

```sh
make c-test C_TEST=plic_uart_irq CYCLES=200000
```

DTBには `interrupt-controller@c000000` とUARTの `interrupts = <10>` を追加済みです。PLIC付きDTBでもOpenSBI platform info表示とS-mode payload到達を確認済みです。Linux通常consoleは次の確認対象です。

OpenSBIからS-mode payloadへ入る確認も通っています。

```text
OpenSBI S-mode payload reached
hartid=0x0000000000000000 dtb=0x0000000087f00000
SBI base spec=0x0000000001000000 error=0x0000000000000000
test success!
```

Linux 6.12.y `Image` の投入も開始済みです。OpenSBIから `0x80200000` のLinux先頭へジャンプし、Linux earlyconのboot logが出るところまで確認できています。

```text
[    0.000000] Linux version 6.12.97 ...
[    0.000000] Machine model: MiNTs-CPU
[    0.000000] SBI TIME extension detected
[    0.000000] SBI IPI extension detected
[    0.000000] SBI RFENCE extension detected
[    0.000000] earlycon: uart8250 at MMIO 0x0000000010000000
[    0.000083] sched_clock: 64 bits at 50MHz, resolution 20ns
[    0.374245] devtmpfs: initialized
[    0.586990] pinctrl core: initialized pinctrl subsystem
[    1.146383] HugeTLB: registered 2.00 MiB page size
[    1.497943] raid6: int64x2  gen()     4 MB/s
```

過去にはLinuxの `.Lsecondary_park` に入っていましたが、`satp` WARLと`satp/sfence.vma`時のfetch flushを直した後は、Sv39有効化後の高位仮想アドレス `ffffffff...` 側でLinux kernelを実行できています。

```text
[HEARTBEAT] pc=ffffffff80108938 mode=1 satp=8000000000081005
```

`sched_clock` 後も、`TRACE_PIPE` / `TRACE_HEARTBEAT` で `minstret` が増え続けることを確認しています。Linux側のPCは `timekeeping_advance`、`ktime_get_update_offsets_now`、`do_irq`、spinlock周辺へ進み、M-mode側ではOpenSBIの `_trap_handler`、`sbi_timer_event_start`、`mtimer_event_start` に入っています。

つまり現時点の判断は、CPUが完全停止しているのではなく、Linux初期化をVerilator上で非常に遅く進めている状態です。PLIC付きDTBと `console=ttyS0,115200` を入れた後も、devtmpfs、pinctrl、DMA pool、HugeTLB、raid6 initまでは進みます。次の本当の修正点は、`minstret` が増えなくなる、panic/oops/illegal instruction/page faultが出る、または同一PCで長時間固定される箇所を見て決めます。

## 現在の出力経路

Linuxから見ると、consoleはDTBで指定したNS16550A互換UARTです。

```text
Linux
  -> UART MMIO 0x10000000 にstore
  -> CPU data path / Sv39 / PMP / MMIO decode
  -> uart_ns16550.sv
  -> Verilator C++ testbench stdout
  -> make run-opensbiを実行しているterminal
```

今はFPGAの物理UARTではなく、Verilatorの標準出力へ文字を流しています。将来FPGAへ載せる場合は、同じUART MMIOをFPGA boardのUART TX pinへ接続し、USB serial経由でPC terminalに表示する形になります。

## 時間の見方

ログには3種類の時間があります。

```text
cycle
  CPUクロック何回分進んだか。
  DTB上の clock-frequency = 50MHz 想定なら cycle / 50,000,000 秒。

mtime / Linux timestamp
  Linuxがclocksourceとして見る時間。
  `src/aclint_memory.sv` では mtime がCPUクロックごとに1増える。
  現在はCPU clock 50MHz想定に合わせて、DTB上の timebase-frequency も50MHzにする。

Verilator実行時間
  macOS上でRTLを1cycleずつ評価する実時間。
  FPGA実行時間よりかなり遅い。TRACEを出すとさらに遅い。
```

例:

```text
[    0.000083] sched_clock: 64 bits at 50MHz
```

これはLinuxが認識している起動後時刻が `0.000083` 秒、つまり `83us` という意味です。

一方、`cycle=0x2ef00000` は10進数で `787,480,576` cycleです。CPU clockを50MHzとみなすと、FPGA上のCPUクロック換算では約 `15.75` 秒分です。ただしVerilator上でこれを進めるには、実時間ではそれ以上かかります。

注意:

過去のDTBでは `timebase-frequency = <1000000>` としていましたが、RTL実装では `mtime` が毎CPUクロック増えていました。CPU clockを50MHzと見なすと、Linux/OpenSBIへ1MHz timerと伝えるのは50倍速timerとして見えるため、timer interruptが過剰に発生する可能性があります。短期的にはDTBを実装実態に合わせて `timebase-frequency = <50000000>` とし、将来的に1MHz timerにしたい場合はRTL側で `mtime` を分周します。

## 停止判定

`minstret` はretireした命令数です。

```text
minstretが増えている
  -> CPUは命令を完了し続けている
  -> 少なくとも完全停止ではない

minstretが長時間増えない
  -> pipeline stall、WFI待ち、MMIO応答待ち、trap loopなどを疑う

Linuxログだけ止まっている
  -> printkが出ない処理中の可能性がある
  -> TRACE_HEARTBEATでPC/minstretを見る
```

通常の長時間実行では `+TRACE_PIPE` を外します。`+TRACE_PIPE` は文字列出力が重く、Linux bootではシミュレーションを大きく遅くします。

## 修正済み: string_get_size loop

Linux boot中に `lib/string_helpers.c:string_get_size()` 付近で長時間進まない状態がありました。

該当箇所では概ね次の計算をします。

```text
size = 0x200000
blk_size = 1
size * blk_size
size / 1024 / 1024
表示用に 10 倍しながら桁を整える
```

トレースでは、`mul a5,a1,a0` に対して `a0=0x200000`, `a1=1` なのに、修正前は `a5=0` になっていました。原因はMUL演算器そのものではなく、coreのEX stageと `muldivunit` のhandshakeでした。

修正前:

```text
現在のMUL requestはまだacceptされていない
  しかし前のmul/divのrvalid/resultが返る
  その古いresultを現在のMUL結果として使う
```

修正後:

```text
exs_muldiv_accept = exs_muldiv_valid && exs_muldiv_ready
requestがacceptされた命令だけrvalid/resultを待つ
request前の古いrvalidは現在の命令の完了として扱わない
```

確認:

```sh
make c-test C_TEST=muldiv_string_size CYCLES=200000
make test-rv64um
```

Linux側でも `mul a5,a1,a0` のwritebackが `0x200000` になり、その後 `divu` と表示用の10倍ループへ進むことを確認しました。

## 起動方法

OpenSBIはrepo外でビルドした `fw_jump.bin` を指定します。

```sh
make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin
```

OpenSBIから小さいS-mode payloadへ入る確認は以下です。

```sh
make test-opensbi-payload OPENSBI_BIN=/path/to/fw_jump.bin
```

Linux Imageを同時に置く場合は、`0x80200000` へ配置します。

```sh
make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=/path/to/Image
```

ローカルmacOS環境ではLinux kernel buildに必要なhost toolとheaderが合わなかったため、Linux kernelはDocker内でビルドしています。macOS上のcloneをDockerへ直接mountすると、macOS用に生成された `scripts/kconfig/conf` をLinuxコンテナが実行して失敗したため、Docker volume上のLinux filesystemへcloneしてビルドします。

```sh
mkdir -p /private/tmp/linux-out

docker run --rm \
  -v linux612-src:/linux \
  -v /private/tmp/linux-out:/out \
  -w /linux \
  debian:bookworm \
  bash -lc 'set -e; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential bc bison flex libssl-dev libelf-dev \
      ca-certificates git dwarves \
      gcc-riscv64-linux-gnu binutils-riscv64-linux-gnu; \
    if [ ! -d .git ]; then \
      git clone --depth 1 --branch linux-6.12.y \
        https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git /linux; \
    fi; \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- defconfig; \
    scripts/config --disable SMP --disable NET --disable MODULES \
      --enable SERIAL_8250 --enable SERIAL_8250_CONSOLE \
      --enable SERIAL_EARLYCON --enable RISCV_SBI --enable PRINTK; \
    make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- olddefconfig; \
    make -j4 ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- Image; \
    cp arch/riscv/boot/Image /out/Image-linux-6.12-riscv64'
```

生成済み:

```text
/private/tmp/linux-out/Image-linux-6.12-riscv64
/private/tmp/linux-out/vmlinux-linux-6.12-riscv64
/private/tmp/linux-out/System.map-linux-6.12-riscv64
```

初回に使ったImageは約25MiBです。`defconfig` ベースのためGPU、USB、SCSI、ACPIなど余分なdriverも多く、次回以降はbring-up用configとしてさらに削る方針です。

その後、Verilator上でraid6 benchmarkやjitterentropy/crypto周辺が非常に遅いことを確認したため、`allnoconfig` ベースのbring-up用Imageも用意しました。

```text
/private/tmp/linux-out/Image-linux-6.12-riscv64-minbringup
/private/tmp/linux-out/vmlinux-linux-6.12-riscv64-minbringup
/private/tmp/linux-out/System.map-linux-6.12-riscv64-minbringup
/private/tmp/linux-out/config-linux-6.12-riscv64-minbringup
```

このImageは約3MiBです。設定の意図は `platform/linux_minbringup.fragment` に残しています。残すものは、SBI、Device Tree、RISC-V timer、SiFive PLIC、8250 UART console、proc/sysfs/devtmpfs、ELF/initrd周辺です。削るものは、SCSI、ATA、MD/RAID6、USB、media、sound、PCI、ACPI、network、jitterentropyなど、最初のCPU/SoC bring-upには不要でシミュレーションを重くするsubsystemです。

実行例:

```sh
make run-opensbi \
  OPENSBI_BIN=/private/tmp/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=/private/tmp/linux-out/Image-linux-6.12-riscv64-minbringup \
  OPENSBI_CYCLES=0
```

確認済みログ:

```text
riscv-plic: interrupt-controller@c000000: mapped 32 interrupts with 1 handlers for 2 contexts.
Serial: 8250/16550 driver, 4 ports, IRQ sharing disabled
10000000.serial: ttyS0 at MMIO 0x10000000 (irq = 1, base_baud = 230400) is a 16550A
printk: legacy console [ttyS0] enabled
Kernel panic - not syncing: VFS: Unable to mount root fs on "" or unknown-block(0,0)
```

このpanicはrootfs/initramfsをまだ渡していないための期待結果です。つまり、OpenSBIからLinuxへ入り、Sv39、timer、PLIC、通常8250 console登録までは通過しています。

BusyBox initramfsも確認しました。ここで見えた初期問題は2つでした。

1. `/init` をshell scriptとして実行するには `CONFIG_BINFMT_SCRIPT=y` が必要
2. BusyBox本体が `double-float ABI` だと、`rv64imac/lp64` の現在のCPUではU-mode illegal instructionになる

そのため、既製の `riscv64/busybox:musl` imageは使わず、`rv64imac/lp64` soft-float向けのstatic BusyBoxを作っています。

補助スクリプト:

```sh
tools/build-rv64imac-musl-toolchain.sh
tools/build-rv64imac-busybox.sh
tools/build-linux-busybox-initramfs-image.sh
```

`tools/build-rv64imac-musl-toolchain.sh` はDocker上のUbuntu環境で `rv64imac/lp64` musl toolchainを `build/riscv-musl-lp64` に作ります。`tools/build-rv64imac-busybox.sh` はそのcompilerでstatic BusyBoxを作ります。`tools/build-linux-busybox-initramfs-image.sh` はBusyBox入りinitramfsをbuilt-inしたLinux Imageを作ります。

Linux sourceはDocker volume `linux-6.12-src` に置く運用を推奨します。macOSの通常filesystemでは `Documentation/Kbuild` と `Documentation/kbuild/` がcase-insensitiveに衝突し、kernel buildの `mrproper` やout-of-tree buildが壊れるためです。

BusyBox入りImage作成:

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

確認済み到達点:

```text
Run /init as init process
BusyBox userspace on MiNTs-CPU
Type commands. Example: uname -a
/bin/sh: can't access tty; job control turned off
~ #
```

ここまでで、Linux kernelからU-modeのPID 1を起動し、BusyBox shellまで到達しています。`can't access tty; job control turned off` は制御TTY未整備による残課題で、Linux + BusyBoxの起動失敗ではありません。

Linux通常consoleで `BusyBox userspac` の16文字だけ表示されて止まる問題は、16550のTHR empty interruptが再発行されていないことが原因でした。Linux 8250 driverはFIFOサイズ分を送った後、次の送信をTHRE interruptで進めます。`src/uart_ns16550.sv` ではTHR write後に即時送信完了扱いとして、`IER[1]` が有効なら `tx_irq_pending` を再度立てるようにしています。

入力表示については、Verilator host terminal側のechoとLinux側のechoが二重になると `^?` などが見えやすくなります。`src/tb_verilator.cpp` では `ICANON | ECHO` を無効化し、Ctrl-C用の `ISIG` は残す方針です。

RAM配置:

| Address | 内容 |
|---:|---|
| `0x80000000` | OpenSBI `fw_jump.bin` |
| `0x80200000` | Linux ImageまたはS-mode payload |
| `0x87f00000` | DTB |

## OpenSBI向けに追加したplatform経路

### Linux/OpenSBI用bootrom

`platform/bootrom_linux.S` を追加し、Linux/OpenSBI boot ABIに近い形で次の値を設定してからRAMへジャンプします。

```asm
li      a0, 0x0
li      a1, 0x87f00000
li      t0, 0x80000000
jr      t0
```

意味:

- `a0 = 0`: hart ID
- `a1 = 0x87f00000`: DTBの物理アドレス
- `0x80000000`: OpenSBIの配置先

OpenSBIはこのDTBを読み、UARTなどのplatform deviceを認識します。

### RAM image生成

`tools/make_linux_ram_hex.py` で、OpenSBI本体、DTB、任意のLinux Imageを1つのRAM hexへまとめます。

`Makefile` 側では以下を追加しています。

- `dtb`
- `linux-bootrom-build`
- `linux-ram-image`
- `test-linux-bootargs`
- `opensbi-ram-image`
- `run-opensbi`
- `opensbi-payload-build`
- `test-opensbi-payload`

`run-opensbi` は最終的に以下の形でsimulatorを起動します。

```sh
DBG_ADDR=0x40000000 obj_dir/sim build/platform/bootrom_linux.hex build/platform/opensbi_ram.hex 50000000
```

### DTB

`platform/riscv_cpu.dts` を追加し、現RTLのaddress mapに合わせました。

主な設定:

- RAM: `0x80000000` から `128MiB`
- UART: `0x10000000`
- PLIC: `0x0c000000`
- CLINT互換node: `0x02000000`
- CPU ISA: `rv64imac_zicsr`
- MMU: `riscv,sv39`
- bootargs: `earlycon=uart8250,mmio,0x10000000 ignore_loglevel`

UART node:

```dts
uart0: serial@10000000 {
	compatible = "ns16550a";
	reg = <0x0 0x10000000 0x0 0x100>;
	interrupt-parent = <&plic>;
	interrupts = <10>;
	clock-frequency = <0x00384000>;
	current-speed = <115200>;
	reg-shift = <0>;
	reg-io-width = <1>;
	status = "okay";
};
```

この結果、OpenSBIログで以下が出るようになりました。

```text
Platform Console Device   : uart8250
```

CLINT互換node:

```dts
clint: clint@2000000 {
	compatible = "riscv,clint0";
	reg = <0x0 0x02000000 0x0 0x0000c000>;
	interrupts-extended = <&cpu0_intc 3>,
	                      <&cpu0_intc 7>;
};
```

OpenSBI v1.3.1では `riscv,clint0` がMSWI/IPI driverとMTIMER driverの両方に拾われます。interrupt番号はRISC-V privileged architectureのmachine software interrupt `3` とmachine timer interrupt `7` です。

この結果、OpenSBIログで以下が出るようになりました。

```text
Platform IPI Device       : aclint-mswi
Platform Timer Device     : aclint-mtimer @ 50000000Hz
```

### NS16550A互換UART

`src/uart_ns16550.sv` を追加し、Linux earlycon / OpenSBI consoleが使いやすい形の最小UARTを実装しました。

対応済み:

- `THR` writeでVerilator標準出力へ1文字出力
- `RBR` readでVerilator stdinから取り込んだ1文字を返す
- `LSR[0] = DR` で受信データありを示し、`RBR` readでclearする
- `LSR[5] = THRE`, `LSR[6] = TEMT` を常に1として返す
- `LCR.DLAB` による `DLL/DLM` 切り替え
- `IER`, `LCR`, `MCR`, `SCR` の保持
- interruptなしなら `IIR = 0x01`
- RX interrupt pending時は `IIR = 0x04`
- THRE interrupt pending時は `IIR = 0x02`
- `MSR = 0`
- byte laneを見て、byte storeされた文字を取り出す

UART RXは `ENABLE_DEBUG_INPUT` 付きsimulatorで有効です。Linuxから対話入力を試す場合は通常の `run-opensbi` ではなく、入力対応simulatorを使う `run-opensbi-input` を使います。

```sh
make run-opensbi-input \
  OPENSBI_BIN=/path/to/fw_jump.bin \
  LINUX_IMAGE_BIN=build/linux-out/Image-linux-6.12-riscv64-hello-initramfs \
  OPENSBI_CYCLES=0
```

MMIO decodeは `src/mmio_controller.sv` 側で、`0x10000000..0x100000ff` をUARTへ流します。

### 最小PLIC

`src/plic.sv` を追加し、SiFive PLIC互換に寄せた最小レジスタ配置を実装しました。

```text
base = 0x0c000000
sources = 32
UART IRQ = 10
context 0 = M-mode external interrupt
context 1 = S-mode external interrupt
```

実装済み:

- `0x000000 + 4 * irq`: priority
- `0x001000`: pending
- `0x002000 + 0x80 * context`: enable
- `0x200000 + 0x1000 * context`: threshold
- `0x200004 + 0x1000 * context`: claim/complete

CPU側ではPLICのcontext 0出力を `mip.MEIP`、context 1出力を `mip.SEIP` に接続しました。M-mode側の `mie.MEIE` もwrite可能にしています。

現在確認済み:

- priority / enable / threshold のreadback
- UART `IER[1]` でTHRE interrupt pending
- PLIC M-context claimでIRQ 10が返る
- M-mode external interrupt `mcause=0x800000000000000b`
- PLIC S-context claimでIRQ 10が返る
- S-mode external interrupt `scause=0x8000000000000009`

未確認/未完:

- Linux通常consoleでの8250 interrupt動作
- RX入力、FIFO、厳密なlevel gateway動作

### S-mode payload

`platform/opensbi_payload_entry.S` / `platform/opensbi_payload.c` は、OpenSBI handoff確認用の最小S-mode payloadです。

配置:

```text
0x80200000 opensbi_payload.bin
```

確認していること:

- OpenSBIが `Domain0 Next Address = 0x80200000` へS-modeで遷移する
- `a0 = hartid = 0`
- `a1 = DTB address = 0x87f00000`
- S-mode payloadからSBI legacy console putcharを呼べる
- S-mode payloadからSBI Base extensionを呼べる
- 最後にdebug MMIOへ成功コードを書いてsimulationを終了できる

## OpenSBI起動のために直したCPU側の問題

### 0. PMP entry数

症状:

OpenSBIは `Next Address = 0x80200000` へS-modeで遷移していましたが、payload先頭fetchが `instruction access fault` になっていました。

確認ログ:

```text
[PAYLOAD] pc=0000000080200000 inst=00000000 trap=1 expt=1 cause=1 value=0000000080200000
```

原因:

CPUが `pmpaddr0..3` の4 entriesだけを実装しており、OpenSBIからは `Boot HART PMP Count : 4` と見えていました。OpenSBIはfirmware領域、CLINT領域、残りのS/U許可領域をPMP domainとして扱うため、4 entriesでは `0x80200000` payload領域を許可するPMP entryが足りませんでした。

修正:

- `pmpcfg0` の8 byte分を有効化
- `pmpaddr4..7` CSRを追加
- `pmp_checker.sv` を8 entries評価に拡張
- data/fetch両方のPMP checkerへ `pmpaddr4..7` を接続

結果:

```text
Boot HART PMP Count       : 8
[PAYLOAD] pc=0000000080200000 inst=00004117 trap=0
```

これによりOpenSBIからS-mode payloadの命令fetchが通るようになりました。

### 1. store命令の完了条件

症状:

OpenSBIがBSS初期化付近で進まなくなりました。store requestは出ているのに、CPU側が完了扱いにできていませんでした。

原因:

`memunit` が通常storeでもread responseの `rvalid` を待っていました。通常storeはread dataを返さないため、そこで止まります。

修正:

`src/memunit.sv` で、通常storeは `membus.ready` で完了するようにしました。

現在の流れ:

```text
store
  -> membus.valid / membus.wen
  -> membus.ready
  -> 完了
```

load / AMOは従来どおり `rvalid` を待ちます。

### 2. 64bit fetch word境界をまたぐ32bit命令

症状:

OpenSBIが途中で不正なアドレスへジャンプしました。調査すると、`0x8000744e` 付近の命令がELF上の命令と一致していませんでした。

期待値:

```text
0x4131c0ef
```

実際にCPUが見ていた値:

```text
0x85bec0ef
```

原因:

PC offsetが6の位置にある32bit命令は、64bit fetch wordをまたぎます。

```text
fetch word N     の上位16bit
fetch word N + 1 の下位16bit
```

を組み合わせる必要があります。

しかし、`inst_fetcher` がFIFOを実際にpopできたタイミングではなく、`fetch_fifo_rvalid` だけで上位16bitを保存していたため、同じfetch wordの下位16bitを次wordの下位16bitとして使うことがありました。

修正:

`src/inst_fetcher.sv` で、offset 6の32bit命令の上位16bit保存条件を以下に変更しました。

```text
fetch_fifo_rready && fetch_fifo_rvalid
```

これにより、「実際にFIFOを読み進めたサイクル」でだけ保存され、境界またぎ命令が正しく復元されます。

### 3. 未実装CSR access

症状:

OpenSBIは起動時にCSRをprobeします。未実装CSRがtrapせずに読めてしまうと、OpenSBIが「そのCSRは存在する」と誤認識する可能性があります。

原因:

未実装CSR readが明示的にillegal instructionになっていませんでした。また、default read valueに不定値が混ざる余地がありました。

修正:

`src/csrunit.sv` に `csr_is_implemented()` を追加し、未実装CSR accessを `ILLEGAL_INSTRUCTION` にしました。

```text
CSR instruction
  -> csr_is_implemented(csr_addr) == 0
  -> illegal instruction trap
```

また、OpenSBIが読む基本ID CSRとして `MVENDORID` と `MARCHID` を定義し、read-only zeroとして返すようにしました。

関連:

- `src/eei.sv`: `MVENDORID = 12'hf11`, `MARCHID = 12'hf12`
- `src/csrunit.sv`: `MVENDORID`, `MARCHID` read path
- `src/csrunit.sv`: `csr_is_implemented()`

### 4. CLINT互換mtime address

症状:

OpenSBI generic platformにtimerを認識させるには、OpenSBIが知っているDTB bindingとRTLのMMIO配置を一致させる必要がありました。

元のRTL:

```text
base + 0x0000 : msip
base + 0x4000 : mtimecmp
base + 0x7ff8 : mtime
```

これは `mtimecmp` がCLINT寄り、`mtime` がACLINT MTIMER寄りの配置でした。

OpenSBI v1.3.1で `compatible = "riscv,clint0"` を使うと、driverは次のように解釈します。

```text
base + 0x0000 : msip
base + 0x4000 : mtimecmp
base + 0xbff8 : mtime
```

修正:

`src/aclint_memory.sv` で、既存の `base + 0x7ff8` を残したまま、CLINT互換の `base + 0xbff8` でも同じ `mtime` をread/writeできるaliasを追加しました。

また、reset直後に不要なMTIP pendingを出さないように、`mtimecmp0` のreset値を `~0` にしました。

関連:

- `src/eei.sv`: `MMAP_CLINT_MTIME = 0xbff8`
- `src/aclint_memory.sv`: `MMAP_ACLINT_MTIME` と `MMAP_CLINT_MTIME` を同じ `mtime` へ接続

## 確認したテスト

OpenSBI以外の既存経路が壊れていないことも確認しています。

```sh
make build
make test-os2-min
make test-uart-regs
make test-rv64si TEST_TIMEOUT=20
make test-mtime
make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin
```

確認内容:

- SystemVerilog buildが通る
- 独自M-mode/S-mode/SBI/timer testが通る
- UART register testが通る
- `rv64si` suiteが通る
- OpenSBI v1.3.1のUART bannerが出る
- Linux 6.12.y Imageを `0x80200000` に置き、OpenSBIからS-mode Linuxへhandoffできる
- Linux earlyconで `Linux version 6.12.97` から memory init、SLUB、RCU、`riscv-intc`、clocksource、`sched_clock` までのboot logが出る

## Linux earlycon到達時に直したこと

Linux投入後、最初は `satp=a000...` になり、CPUが未実装のSv57を受け入れていました。`satp` はWARL CSRなので、現在の実装ではMODE=0(Bare)とMODE=8(Sv39)だけを受理し、Sv48/Sv57など未対応MODEのwriteは現在値を維持するようにしました。これによりLinuxのsatp mode probeが正しく失敗し、Sv39へ降格します。

次に、`csrw satp` 後もfetch済みの物理アドレス命令を実行してしまい、Linux `head.S` の `load_global_pointer` が物理PCで実行され、`gp=0x81b39490` のまま高位kernelへ入っていました。この状態では `gp` 相対のglobal参照が `0x81b38eb8` などの低いVAになり、page faultからpanicへ進みます。

そのため、MEM段で次の命令をtranslation hazardとして扱い、フロントエンドをflushして `pc+4` からfetchし直すようにしました。

- `satp` CSR access
- `sfence.vma`

修正後は、trampoline `satp` write直後に `0x80201048` fetchがinstruction page faultとなり、Linuxが設定した `stvec=0xffffffff80001048` へ入ります。その後、`load_global_pointer` が高位PCで実行され、`gp=0xffffffff81939490` に更新されることを確認しました。

既知の残件:

- `rv64mi-p-breakpoint` は現在fail
- Linuxはearlycon / memory init / clocksourceまでは到達。次はboot logが止まる地点の特定、PLIC、通常console、initramfs

## 次にやること

次の主作業はLinux boot logが止まる地点の特定です。現時点では `Linux version ...` とearlycon出力は確認済みなので、timer interrupt、SBI call、PLIC不在、通常console初期化、initramfs未設定のどこで詰まるかを順番に切り分けます。
