# RISC-V CPU in SystemVerilog

`cpu.kanataso.net` の教材「Verylで作るCPU」を参考に、Veryl 実装を SystemVerilog で実装し直している RISC-V CPU です。

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
| MMIO | Implemented | RAM, ROM, debug I/O, ACLINT, DMA へ decode |
| CSR | Implemented | Machine/Supervisor/User 関連 CSR を部分実装 |
| Exceptions | WIP | illegal instruction, ECALL, EBREAK, misaligned access など |
| Interrupts | WIP | ACLINT の software/timer interrupt を CSR unit に接続 |
| Privilege modes | WIP | M/S/U mode、trap delegation、`MRET`/`SRET` を部分実装 |

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
make test-rv32ui TEST_TIMEOUT=20 -> PASS 42 / 42
make test-rv64ui TEST_TIMEOUT=20 -> PASS 53 / 54
```

`rv64ui-p-ma_data` は現状 fail します。

より広い suite の結果は `Docs/TEST_STATUS.md` を参照してください。注意点として、`F`, `D`, `Zb*`, `Zfh` 系は pass している rv32 suite もありますが、現状の実装から正式サポートとは扱っていません。

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
make test-os2-min-smode
make test-os2-min-strap
make test-os2-min-sbi
make test-os2-min-sbi-input INPUT_TEXT=Z
make test-os2-min-sbi-timer
```

`core/test/os2_min/` は `/Users/shiraitouma/OS2` から `common.c` / `common.h` / `kernel.h` / `kernel.ld` をコピーし、このCPUで最初に動かすために `kernel.c` を最小化したものです。現時点では SBI、virtio-blk、paging、U-mode process は使わず、OS2由来の `printf` と `getchar` が debug MMIO `0x40000000` 経由で動くことを確認する段階です。

`os2_min` の生成物 `.elf` / `.bin` / `.bin.hex` は `build/os2_min/` に出力します。`core/test/os2_min/` にはソース、ヘッダ、リンカスクリプトだけを置く方針です。

通常のCテスト生成物は `build/test/c_tests/`、bootrom生成物は `build/test/` に出力します。`core/test/` 直下にはテストソースとスクリプトだけを置く方針です。

この最小移植版は今後RVA23方向へ進める前段として、RV64 kernel前提に寄せています。`size_t` / `paddr_t` / `vaddr_t` / trap frame / CSR helper は64-bit幅に整理し、paging定義はSV32ではなくSV39を戻す前提にしています。

`make test-os2-min-smode` は M-mode boot code から `mstatus.MPP=S` と `mepc=supervisor_main` を設定し、`mret` でS-modeへ遷移できることを確認します。Linux起動を目標にする場合、本来の syscall は U-mode から S-mode へ入る `ecall` として実装し、S-mode trap、最小SBI、U-mode syscall、Sv39の順で進めます。

`make test-os2-min-strap` は S-mode `ecall` を `stvec` で受けるテストです。`medeleg[9]` で S-mode ecall を S-mode trap へ委譲し、handler で `sepc += 4` して `sret` で元のS-mode処理へ戻れることを確認します。

`make test-os2-min-sbi` は S-mode `ecall` を M-mode `mtvec` で受ける最小SBI経路のテストです。`medeleg[9]` を立てず、S-mode側の `a7/a6/a0` を M-mode trap handler で読み、debug console putchar を実行してS-modeへ戻ります。`make test-os2-min-sbi-input INPUT_TEXT=Z` は同じ経路で debug console getchar を確認します。

`make test-os2-min-sbi-timer` は M-modeが `mcounteren.TIME` を許可したうえで、S-mode が `time` CSR から絶対時刻を読み、SBI TIME `set_timer` を呼ぶテストです。M-mode firmware が ACLINT `mtimecmp` を設定し、その後 machine timer interrupt が M-mode trap handler へ入ることを確認します。

今後の実装方針は `Docs/ROADMAP.md` に、機能ごとの進捗と次タスクは `Docs/TASK_STATUS.md` に整理しています。

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
