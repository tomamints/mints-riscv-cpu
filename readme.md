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
| MMIO | Implemented | RAM, ROM, debug I/O, ACLINT, DMA, NS16550A最小UARTへ decode |
| CSR | Implemented | Machine/Supervisor/User 関連 CSR を部分実装 |
| Exceptions | WIP | illegal instruction, ECALL, EBREAK, misaligned access など |
| Interrupts | WIP | ACLINT の software/timer interrupt を CSR unit に接続 |
| Privilege modes | WIP | M/S/U mode、trap delegation、`MRET`/`SRET` を部分実装 |
| PMP | WIP | 4 entries、TOR/NAPOT、data/fetch check。S-mode allow-all、禁止load/store/fetch faultを確認 |
| Sv39 | WIP | `satp.MODE=8`、3-level PTW、data/fetch translation、basic page faultを確認 |
| UART | WIP | `0x10000000` にNS16550A互換の最小TX/LSRを追加。polling byte writeを確認 |

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
make test-uart-regs
```

`uart_output.c` は NS16550A 互換UARTの `LSR` をpollingし、`THR` へbyte writeします。現在のUART baseは `0x10000000`、byte-spaced registerで、`LSR[5]=THRE` と `LSR[6]=TEMT` を常に1として返します。このテストで `A` と success まで到達することを確認済みです。

`uart_regs.c` は `IER/MCR/SCR/LCR` の保持、`LCR.DLAB=1` 時の `DLL/DLM` 切り替え、`IIR=0x01`、`MSR=0`、`LSR.THRE/TEMT=1` を確認します。Linux earlyconやOpenSBIのUART初期化で触る可能性がある最小レジスタ群のbring-up確認です。

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

`core/test/os2_min/` は `/Users/shiraitouma/OS2` から `common.c` / `common.h` / `kernel.h` / `kernel.ld` をコピーし、このCPUで最初に動かすために `kernel.c` を最小化したものです。現時点では SBI、PMP、timer、最小U-mode entry/ecall、Sv39 data-side identity mapping、fetch-side identity mapping、SUM/MXRの基本permissionを小さく確認しています。virtio-blk、本格的なU-mode process管理はまだ戻していません。

`os2_min` の生成物 `.elf` / `.bin` / `.bin.hex` は `build/os2_min/` に出力します。`core/test/os2_min/` にはソース、ヘッダ、リンカスクリプトだけを置く方針です。

通常のCテスト生成物は `build/test/c_tests/`、bootrom生成物は `build/test/` に出力します。`core/test/` 直下にはテストソースとスクリプトだけを置く方針です。

この最小移植版は今後RVA23方向へ進める前段として、RV64 kernel前提に寄せています。`size_t` / `paddr_t` / `vaddr_t` / trap frame / CSR helper は64-bit幅に整理し、paging定義はSV32ではなくSV39を戻す前提にしています。

`make test-os2-min` は入力不要の統合テストです。M-mode boot code でPMP NAPOT allow-allを設定し、`mstatus.MPP=S` と `mepc=supervisor_main` を設定してS-modeへ入ります。その後、S-modeからSBI debug console putchar、SBI TIME `set_timer` を順に確認します。timer testでは M-modeが `mcounteren.TIME` を許可したうえで、S-mode が `time` CSR から絶対時刻を読み、M-mode firmware が ACLINT `mtimecmp` を設定します。その後 `MTIP -> M-mode trap handler -> STIP注入 -> S-mode stvec` の順に進み、S-mode timer interruptとして3回受け、`sip.STIP` clear、`sret` 復帰、次回timer再設定を確認します。

`make test-os2-min-input INPUT_TEXT=Z` は入力ありのSBIテストです。S-modeからSBI debug console getcharを呼び、入力文字を取得してdebug console putcharで出力します。

`make test-os2-min-strap` は S-mode `ecall` を `stvec` で受けるテストです。`medeleg[9]` で S-mode ecall を S-mode trap へ委譲し、handler で `sepc += 4` して `sret` で元のS-mode処理へ戻れることを確認します。

`OS2_MIN_PMP` は PMP access fault のテストです。M-modeでPMP entry1に `pmp_protected_word` の8byteだけTOR禁止領域を作り、entry2をNAPOT allow-allにします。その後S-modeから禁止wordをload/storeし、loadでは `scause=5`、storeでは `scause=7`、どちらも `stval=fault address` でS-mode trapへ入り、handlerで `sepc += 4` して復帰できることを確認します。さらにM-mode SBIで保護wordを読み直し、禁止storeがRAMを書き換えていないことも確認します。fetch側は、`pmp_protected_exec_target` を `X=1/R=0/W=0` にした場合は実行でき、`R=1/W=1/X=0` にした場合は `scause=1`、`stval=fetch address` でS-mode trapへ入ることを確認します。さらに32-bit命令を4byte境界+2に置き、命令後半2byteだけがX禁止領域に入る場合もinstruction access faultになることを確認します。

`OS2_MIN_USER` は最小U-modeテストです。S-modeで `stvec`、`medeleg[8]`、`sstatus.SPP=U`、`sepc=user_entry` を設定して `sret` し、U-modeへ入ります。U-mode側は1回目の `ecall` でS-mode trapへ入り、handlerが `a0=0x5678` と `sepc += 4` を設定してU-modeへ戻します。2回目の `ecall` はexit syscallとして扱い、S-mode handler側で `test success` を出します。

`make test-os2-min-sv39` は最小Sv39テストです。S-modeで3段page tableを作り、`satp.MODE=8` とroot PPNを設定します。CPU側は `sv39_ptw.sv` に分離したpage table walkerをdata-side load/storeとinstruction fetchの両方から使います。現在はTLBがないため `sfence.vma` はno-opとして受けます。先頭256KiBのRAMとdebug MMIO 1ページを4KiB leaf PTEでidentity mapし、S-modeのload/store/fetchがVA->PA変換後に成功すること、2MiB L1 / 1GiB L2 superpage aliasでloadできること、未mapの `0x60000000` loadが `scause=13`、`stval=0x60000000` のload page faultになることを確認します。加えて、S-modeからUページへのloadが `SUM=0` ではfault、`SUM=1` では成功すること、execute-onlyページへのloadが `MXR=0` ではfault、`MXR=1` では成功すること、`A=0` load、`D=0` store、`W=0` storeがpage faultになること、root page table A/Bの `satp.PPN` を切り替えると同じVAが別PAを読むこと、`X=0` ページへのfetchが `scause=12` のinstruction page faultになることも確認します。

`sv39_ptw.sv` は architectural な `scause` とは別に `Sv39Fault` で内部fault理由も保持します。これはIOMMU側の `ptw_fault_e` と同じ位置づけで、波形や `+TRACE_SV39` でPTE invalid、W without R、reserved bit、permission、A/D不足、superpage misalignmentなどを切り分けるための情報です。A/D bitは現時点ではhardware updateせず、Svade相当のfault方式として扱います。PTW中のPTE読み出し自体が失敗した場合はpage faultではなく、元のアクセス種別に応じてinstruction/load/store access faultへ分類します。

今後の実装方針は `Docs/ROADMAP.md` に、機能ごとの進捗と次タスクは `Docs/TASK_STATUS.md` に整理しています。RVA23方向の棚卸しは `Docs/RVA23_CHECKLIST.md` に分けています。

Linux起動を大目標にするため、U-mode syscallは最小確認で一旦区切っています。次フェーズはSv39の補完、PTWメモリエラー発生源、`sfence.vma` / TLB方針、NS16550A UARTのLinux向けレジスタ補完、DTBです。

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
