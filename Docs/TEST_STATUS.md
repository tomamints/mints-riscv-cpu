# Test Status

この文書は `core/test/share` にある riscv-tests 由来の test binary を、現在の simulator で実行した結果です。

実行日: 2026-07-24

## 実行方法

```sh
make test-suite SUITE=<suite> TEST_TIMEOUT=20
make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full
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
| `rv64ui-p` | 54 / 54 | Pass |
| `rv64um-p` | 13 / 13 | Pass |
| `rv64ua-p` | 19 / 19 | Pass |
| `rv64uc-p` | 1 / 1 | Pass |
| `rv64mi-p` | 17 / 17 | Pass |
| `rv64si-p` | 7 / 7 | Pass |

## Known Failures

今回確認した `rv32/rv64 ui/um/ua/uc/mi/si` の `-p` suite に既知failはありません。

直近で修正した既知fail:

- `rv64ui-p-ma_data`
- `rv64mi-p-illegal`
- `rv64mi-p-instret_overflow`
- `rv64si-p-csr`
- `rv64si-p-dirty`

### Unsupported / Not Claimed

These suites are outside the currently claimed implementation scope and were not part of the latest `make test-riscv-all` core-suite run:

- `rv32uf-p`
- `rv32ud-p`
- `rv32uzba-p`
- `rv32uzbb-p`
- `rv32uzbc-p`
- `rv32uzbs-p`
- `rv32uzfh-p`
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
| RV64I user tests | Good: all `rv64ui-p` pass |
| RV32M / RV64M | Good: all tested M extension cases pass |
| RV32A / RV64A | Good: all tested A extension cases pass |
| RVC | Basic support: `rv32uc-p` and `rv64uc-p` pass |
| Machine privilege tests | Good for current `rv32mi-p` / `rv64mi-p` tests |
| Supervisor privilege tests | Good for current `rv32si-p` / `rv64si-p` tests |
| Floating point | Not claimed |
| Bitmanip / Zb* | Not claimed |
| Cache block / address translation extensions | Not claimed |
| DMA | Implemented experimentally, basic C test passes |
| UART | WIP: NS16550A compatible minimal polling TX and LSR pass |
| PMP | WIP: allow-all, S-mode load/store/fetch access fault, and blocked store side-effect tests pass |
| Sv39 | WIP: data/fetch 3-level 4KiB identity mapping, satp.PPN switch, L1/L2 superpage, load/store/instruction page fault, SUM, MXR, A/D fault pass |

## Custom C Tests

`core/test/*.c` は `Makefile` から build / run できます。

| Target | Source | Result | Notes |
|---|---|---:|---|
| `make test-output` | `core/test/debug_output.c` | Pass | `Hello,world!` と success まで到達 |
| `make test-input INPUT_TEXT=A` | `core/test/debug_input.c` | Pass as manual I/O test | `A` を入力すると `B` が返る。self-terminating test ではなく cycle count で終了する |
| `make test-dma` | `core/test/debug_dma.c` | Pass | DMA register 設定、RAM-to-RAM copy、結果検証、success まで到達 |
| `make test-uart` | `core/test/uart_output.c` | Pass | NS16550A互換UARTの `LSR` をpollingし、`THR` へbyte writeして `A` とsuccessを出力。`0x10000000`のMMIO decode、byte lane read/write、Verilator標準出力を確認 |
| `make test-mswi` | `core/test/mswi.c` | Pass | ACLINT machine software interrupt の handler 到達を確認 |
| `make test-mtime` | `core/test/mtime.c` | Pass | ACLINT machine timer interrupt の handler 到達を確認 |
| `make test-os2-min` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | 入力不要の統合テスト。PMP NAPOT allow-all設定後、S-mode遷移、SBI debug console putchar、SBI TIME `set_timer`、MTIPからSTIP注入、S-mode timer interrupt、periodic timer 3回を確認 |
| `make test-os2-min-input INPUT_TEXT=Z` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | S-modeから最小SBI dispatcher経由で debug console getchar を呼び、入力文字 `Z` を取得して出力 |
| `make test-os2-min-strap` | `core/test/os2_min/kernel.c` | Pass | `medeleg[9]` 設定後に S-mode `ecall` が `stvec` へ入り、handler で `sepc += 4` して `sret` で復帰することを確認 |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=300000` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c`, `firmware.c`, `sbi.c` | Pass | PMP entry1のTOR禁止領域へS-modeからload/store/fetchし、loadは`scause=5`、storeは`scause=7`、fetchは`scause=1`、いずれも`stval=fault address` でS-mode trapへ入ること、禁止storeで保護wordが変化しないことを確認。fetchは`X=1/R=0/W=0`で成功、`R=1/W=1/X=0`でfaultすること、32-bit命令後半2byteがX禁止領域に入るとfaultすることも確認 |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_USER OS2_MIN_NAME=kernel_user CYCLES=120000` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c` | Pass | S-modeから`sstatus.SPP=U`、`sepc=user_entry`、`sret`でU-modeへ入り、U-mode `ecall` が`scause=8`でS-mode trapへ入ること、1回目のsyscall戻り値でU-modeへ復帰できること、2回目をexit syscallとして処理できることを確認 |
| `make test-os2-min-sv39` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c` | Pass | S-modeで3段page tableを作成し、`satp.MODE=8`でdata-sideとfetch-sideのSv39を有効化。identity load/store/fetch、2MiB L1 / 1GiB L2 superpage、未map load page fault、SUM=0/1、MXR=0/1、A=0 load fault、D=0 store fault、W=0 store permission fault、satp.PPN切り替え、X=0 instruction page faultを確認 |

debug MMIO output の重複表示は、`mmio_controller` が device `valid` を response まで出し続けていたことが原因でした。現在は device `ready` で request を issue 済みにし、以後は `rvalid` だけ待つため、debug output / DMA test とも重複なしで pass します。

S-mode `sepc` 更新失敗は、CSR write mask table に `SEPC` がなく `wmask=0` になっていたことが原因でした。現在は `SEPC_WMASK` を適用し、S-mode trap handler から `sepc` を更新できます。
