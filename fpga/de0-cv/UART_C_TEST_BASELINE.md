# UART C テストの基準記録（現 RTL・期待値は変更なし）

記録日: 2026-11-09（UTC 11:08）/ 実行: Claude（Orca worker）/ GO: Codex（`Docs/reviews/UART_REGS_DESIGN_REVIEW_CODEX.md` の「先行作業」）

## 条件
- RTL: 変更なし（`src/uart_ns16550.sv` ほか。HEAD `cd781f9`）。C テスト（`core/test/uart_*.c`）も変更なし。
- 変更したのはハーネスだけ:
  - 復元した `tb/sw/common/{bootrom.S, entry.S, link.ld}`。元のファイルは `.gitignore` のためクローンに存在しなかったので、中身は再作成したもの。
  - Makefile の参照を変数化（`C_TEST_SRC_DIR`、`C_TEST_COMMON_DIR`、`BOOTROM_SRC`、`C_TEST_ENTRY`、`C_TEST_LD`、`C_TEST_HARNESS_DEFS`）。
- 環境: Docker `mints-linux-verilator:5.046`（Verilator 5.046）、`riscv64-linux-gnu-gcc` 13.3.0。
  - gcc は bare-metal 用にするため `-static -fno-pie -no-pie -fno-asynchronous-unwind-tables -Wl,--build-id=none` を追加した。`-march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles` は Makefile の既定値のまま。
- sim の構成: Makefile 既定（DCACHE_LINE_COUNT=128、STORE_BUFFER_DEPTH=4、WRITE_BACK=0）。sim のビルド警告は0。
- 出力先は `build/test/uart-baseline/` で、既存の `obj_dir*` は使わない。
- 実行: `bash tools/test-uart-baseline.sh`

## 判定方法
- 判定はログのマーカーで行う。sim は CYCLES に達しても終了コード0を返すので、`make` の終了コードだけでは PASS にしない。
- PASS = `test success!` あり、かつ `make` の終了コードが0。FAIL = `test failed!` または `%Error`。TIMEOUT = どちらのマーカーもない。
- 注意: 各テストの `fail()` は debug MMIO に **2**（偶数）を書く。`src/top.sv:270-283` は LSB=1 の値だけを終了要求として扱うので、`fail()` に入ったテストは終了せず **TIMEOUT** として現れる。

## 結果

| テスト | 判定 | make 終了コード | 原因（証拠） |
|---|---|---|---|
| `test-uart` | PASS | 0 | `A`、`test success!` |
| `test-uart-input INPUT_TEXT=Z` | PASS | 0 | `test success!` |
| `test-uart-regs` | TIMEOUT | 0 | `[UART IIR] value=c1` に対し `uart_regs.c:40` は 0x01 を期待 → `fail()` |
| `test-uart-tx-irq` | TIMEOUT | 0 | `[UART IIR] value=c2` に対し `uart_tx_irq.c:78` は 0x02 → `fail()`（`F` を表示） |
| `test-uart-tx-seip` | TIMEOUT | 0 | `[UART IIR] value=c2` に対し `uart_tx_seip.c:86` は 0x02 → `fail()`（`F`） |
| `test-uart-rx-seip INPUT_TEXT=Z` | TIMEOUT | 0 | `[UART IIR] value=c4` に対し `uart_rx_seip.c:78` は 0x04 → `fail()`（`F`） |

- 原因の証拠: 同じ sim に `+TRACE_UART` を付けて実行したログ（`build/test/uart-baseline/trace-*.log`）。IRQ 自体は立っており（`irq=1`、PLIC 経由でハンドラに入って IIR を読んでいる）、食い違いは **IIR[7:6]=11** の部分だけ（現 RTL `uart_ns16550.sv:53` は常に `0xc0|...` を返す）。これはレビューで想定していた失敗で、期待値は緩めていない。
- `test-uart-regs` は IIR で止まるため、その先の IER=0x55 の読み返し（現 RTL は 0x05 を返す）などは未評価。

## ハーネスの自己確認
`build/test/uart-baseline/harness-selftest/`（Git の対象外）で、BSS を確認した後に `main` から戻るだけの C ファイルを実行した。
- BSS が0クリアされていること。
- `main` から戻ると `test failed!`、`wdata : 0000000000000003` が出て、`make` の終了コードが2になること。
- 配置: `_start=0x80000000`、`__stack_top=0x800103b0`。bootrom は `li t0,0x80000000; jr t0`。

## 未実施
riscv-tests（`core/test/share` も欠けている）、`test-custom-all` の UART 以外の項目、Linux autotest の再実行、lockstep。
