# RISC-V CPU in SystemVerilog

`cpu.kanataso.net` の教材「Verylで作るCPU」を参考に、Veryl 実装を SystemVerilog で実装し直している RISC-V CPU です。

DMA は教材由来ではなく、このリポジトリで独自に追加している実験的な機能です。

- 参考: https://cpu.kanataso.net/
- U-mode / CSR 章: https://cpu.kanataso.net/22-umode-csr.html

## Current Status

現状は、CPU 本体の移植実装と、独自 DMA の試作が混在している状態です。

`make build` による Verilator build は通ります。ただし、各命令や特権機能の網羅的な回帰テストが整備されている状態ではありません。

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
- busy 中の `SRC` / `DST` / `LEN` 書き換え禁止は仕様としては未整理
- DMA 専用テストはまだ整備されていない

## DMA Register Map

`Docs/DMA.md` は初期 Step1 仕様のままで、一部が現在の実装と一致していません。

現在の実装上の register map は `src/eei.sv` にある以下です。

| Register | Offset |
|---|---:|
| `CTRL` | `0x00` |
| `STATUS` | `0x08` |
| `SRC` | `0x10` |
| `DST` | `0x18` |
| `LEN` | `0x20` |

`Docs/DMA.md` 側では `SRC=0x04`, `DST=0x08`, `LEN=0x0C`, `STATUS=0x10` と書かれているため、現時点では古い情報です。ソフトウェアやテストを書く場合は、`src/eei.sv` の定義を正としてください。

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
ROM=core/test/sample_ecall.hex
RAM=$(ROM)
CYCLES=20
```

## Repository Notes

- `boost_1_88_0/`, `whisper/`, `.DS_Store`, `obj_dir/` は Git 管理対象外です。
- `Docs/DMA.md` は DMA の設計メモですが、現在の実装とは一部ズレがあります。
- 現状の README は、実装の現状を説明するためのものであり、RISC-V 仕様適合性を保証するものではありません。
