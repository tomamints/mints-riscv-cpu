# OpenSBI Bring-up Notes

この文書は、OpenSBI v1.3.1 `FW_JUMP` のUART banner表示、OpenSBIからS-mode payloadへ到達するために行った変更、Linux Image投入の初回結果を残すためのメモです。

現在確認できている到達点:

```text
Boot ROM
  -> OpenSBI at 0x80000000
  -> DTB at 0x87f00000
  -> UART banner output
  -> Next Address 0x80200000, Next Mode S-mode
  -> S-mode payload at 0x80200000
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
Platform Timer Device     : aclint-mtimer @ 1000000Hz
```

このため、OpenSBI generic platformから見たmachine software interrupt / machine timer interruptのplatform device認識は通っています。

OpenSBIからS-mode payloadへ入る確認も通っています。

```text
OpenSBI S-mode payload reached
hartid=0x0000000000000000 dtb=0x0000000087f00000
SBI base spec=0x0000000001000000 error=0x0000000000000000
test success!
```

Linux 6.12.y `Image` の投入も開始済みです。OpenSBIから `0x80200000` のLinux先頭へジャンプし、Linuxの命令実行が始まるところまでは確認できています。

```text
[PAYLOAD] pc=0000000080200000 inst=ff300a13 trap=0 expt=0
[PAYLOAD] pc=0000000080200002 inst=0820106f trap=0 expt=0
```

現時点の停止位置はLinuxの `.Lsecondary_park` です。

```text
[PAYLOAD] pc=0000000080201068 inst=10500073  # wfi
[PAYLOAD] pc=000000008020106c inst=ffdff06f  # jump back
```

`arch/riscv/kernel/head.S` 上では `.Lsecondary_park` は、早期trap、起動hartとして進めなかった場合、secondary hartが戻ってきた場合などに入る退避ループです。現在のbring-upではSMPを無効化しているため、まずは `setup_vm` / `relocate_enable_mmu` 周辺の早期trap、つまりSv39切り替え直後の命令fetch/page fault/trap-vector遷移を優先して調査します。

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
```

初回に使ったImageは約25MiBです。`defconfig` ベースのためGPU、USB、SCSI、ACPIなど余分なdriverも多く、次回以降はbring-up用configとしてさらに削る方針です。

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
- CLINT互換node: `0x02000000`
- CPU ISA: `rv64imac_zicsr`
- MMU: `riscv,sv39`
- bootargs: `earlycon=uart8250,mmio,0x10000000 ignore_loglevel`

UART node:

```dts
uart0: serial@10000000 {
	compatible = "ns16550a";
	reg = <0x0 0x10000000 0x0 0x100>;
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
Platform Timer Device     : aclint-mtimer @ 1000000Hz
```

### NS16550A互換UART

`src/uart_ns16550.sv` を追加し、Linux earlycon / OpenSBI consoleが使いやすい形の最小UARTを実装しました。

対応済み:

- `THR` writeでVerilator標準出力へ1文字出力
- `LSR[5] = THRE`, `LSR[6] = TEMT` を常に1として返す
- `LCR.DLAB` による `DLL/DLM` 切り替え
- `IER`, `LCR`, `MCR`, `SCR` の保持
- `IIR = 0x01`
- `MSR = 0`
- byte laneを見て、byte storeされた文字を取り出す

MMIO decodeは `src/mmio_controller.sv` 側で、`0x10000000..0x100000ff` をUARTへ流します。

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
- Linux earlyconで `Linux version 6.12.97` から `sched_clock` 付近までのboot logが出る

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
