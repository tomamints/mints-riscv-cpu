# Test Status

この文書は `core/test/share` にある riscv-tests 由来の test binary を、現在の simulator で実行した結果です。

実行日: 2026-07-21

## 実行方法

```sh
make test-suite SUITE=<suite> TEST_TIMEOUT=20
```

例:

```sh
make test-rv32ui TEST_TIMEOUT=20
make test-rv64ui TEST_TIMEOUT=20
```

## 注意

この表は「現在の test binary が pass したか」を示します。命令セットとして正式に実装済みであることを常に意味するものではありません。

特に `F`, `D`, `Zb*`, `Zfh` 系は、現状の SystemVerilog 実装に専用 decoder / execution unit が見当たらないため、pass していても正式サポートとは扱いません。trap handler や test binary 側の条件により pass している可能性があります。

現時点で実装から見て主張しやすい範囲は `RV64IMAC`、MMIO、CSR/trap/interrupt の一部、ACLINT、独自 DMA です。

## Summary

| Suite | Result | Status |
|---|---:|---|
| `rv32ui-p` | 42 / 42 | Pass |
| `rv32um-p` | 8 / 8 | Pass |
| `rv32ua-p` | 10 / 10 | Pass |
| `rv32uc-p` | 1 / 1 | Pass |
| `rv32mi-p` | 16 / 16 | Pass |
| `rv32si-p` | 6 / 6 | Pass |
| `rv32uf-p` | 11 / 11 | Pass, but not claimed as implemented |
| `rv32ud-p` | 10 / 10 | Pass, but not claimed as implemented |
| `rv32uzba-p` | 3 / 3 | Pass, but not claimed as implemented |
| `rv32uzbb-p` | 18 / 18 | Pass, but not claimed as implemented |
| `rv32uzbc-p` | 3 / 3 | Pass, but not claimed as implemented |
| `rv32uzbs-p` | 8 / 8 | Pass, but not claimed as implemented |
| `rv32uzfh-p` | 11 / 11 | Pass, but not claimed as implemented |
| `rv64ui-p` | 53 / 54 | Partial |
| `rv64um-p` | 13 / 13 | Pass |
| `rv64ua-p` | 19 / 19 | Pass |
| `rv64uc-p` | 1 / 1 | Pass |
| `rv64mi-p` | 14 / 17 | Partial |
| `rv64si-p` | 3 / 7 | Partial |
| `rv64uf-p` | 0 / 11 | Fail |
| `rv64ud-p` | 0 / 12 | Fail |
| `rv64uzba-p` | 0 / 8 | Fail |
| `rv64uzbb-p` | 0 / 24 | Fail |
| `rv64uzbc-p` | 0 / 3 | Fail |
| `rv64uzbs-p` | 0 / 8 | Fail |
| `rv64uzfh-p` | 0 / 11 | Fail |
| `rv64mzicbo-p` | 0 / 1 | Fail |
| `rv64ssvnapot-p` | 0 / 1 | Fail |
| `rv64uziccid-p` | 0 / 1 | Fail |

## Known Failures

### `rv64ui-p`

- `rv64ui-p-ma_data`

### `rv64mi-p`

- `rv64mi-p-illegal`
- `rv64mi-p-instret_overflow`
- `rv64mi-p-pmpaddr`

### `rv64si-p`

- `rv64si-p-csr`
- `rv64si-p-dirty`
- `rv64si-p-icache-alias`
- `rv64si-p-scall`

### Unsupported / Not Claimed

These suites currently fail on RV64 and are not claimed as supported:

- `rv64uf-p`
- `rv64ud-p`
- `rv64uzba-p`
- `rv64uzbb-p`
- `rv64uzbc-p`
- `rv64uzbs-p`
- `rv64uzfh-p`
- `rv64mzicbo-p`
- `rv64ssvnapot-p`
- `rv64uziccid-p`

## Current Support Estimate

| Area | Support estimate |
|---|---|
| RV32I user tests | Good: all `rv32ui-p` pass |
| RV64I user tests | Mostly working: one known failure |
| RV32M / RV64M | Good: all tested M extension cases pass |
| RV32A / RV64A | Good: all tested A extension cases pass |
| RVC | Basic support: `rv32uc-p` and `rv64uc-p` pass |
| Machine privilege tests | rv32 good, rv64 partial |
| Supervisor privilege tests | rv32 good, rv64 partial |
| Floating point | Not claimed |
| Bitmanip / Zb* | Not claimed |
| Cache block / address translation extensions | Not claimed |
| DMA | Implemented experimentally, basic C test passes |
| PMP | WIP: allow-all and S-mode load access fault test pass |

## Custom C Tests

`core/test/*.c` は `Makefile` から build / run できます。

| Target | Source | Result | Notes |
|---|---|---:|---|
| `make test-output` | `core/test/debug_output.c` | Pass | `Hello,world!` と success まで到達 |
| `make test-input INPUT_TEXT=A` | `core/test/debug_input.c` | Pass as manual I/O test | `A` を入力すると `B` が返る。self-terminating test ではなく cycle count で終了する |
| `make test-dma` | `core/test/debug_dma.c` | Pass | DMA register 設定、RAM-to-RAM copy、結果検証、success まで到達 |
| `make test-mswi` | `core/test/mswi.c` | Pass | ACLINT machine software interrupt の handler 到達を確認 |
| `make test-mtime` | `core/test/mtime.c` | Pass | ACLINT machine timer interrupt の handler 到達を確認 |
| `make test-os2-min` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | 入力不要の統合テスト。PMP NAPOT allow-all設定後、S-mode遷移、SBI debug console putchar、SBI TIME `set_timer`、MTIPからSTIP注入、S-mode timer interrupt、periodic timer 3回を確認 |
| `make test-os2-min-input INPUT_TEXT=Z` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | S-modeから最小SBI dispatcher経由で debug console getchar を呼び、入力文字 `Z` を取得して出力 |
| `make test-os2-min-strap` | `core/test/os2_min/kernel.c` | Pass | `medeleg[9]` 設定後に S-mode `ecall` が `stvec` へ入り、handler で `sepc += 4` して `sret` で復帰することを確認 |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=120000` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c` | Pass | PMP entry1のTOR禁止領域へS-modeからloadし、`scause=5`, `stval=fault address` でS-mode trapへ入ることを確認 |

debug MMIO output の重複表示は、`mmio_controller` が device `valid` を response まで出し続けていたことが原因でした。現在は device `ready` で request を issue 済みにし、以後は `rvalid` だけ待つため、debug output / DMA test とも重複なしで pass します。

S-mode `sepc` 更新失敗は、CSR write mask table に `SEPC` がなく `wmask=0` になっていたことが原因でした。現在は `SEPC_WMASK` を適用し、S-mode trap handler から `sepc` を更新できます。
