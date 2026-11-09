# fpga/de0-cv

Terasic DE0-CV（Cyclone V `5CEBA4F23C7N`）向けのボード層。
この README は現在 **UART PHY（第1段階）** の部分だけを扱う。
Lチカの回路・検証・書込み手順は [`blink/README.md`](blink/README.md) を参照。

## UART PHY（第1段階）— 状態: Verilator 単体テスト PASS（合成・実機は未実施）

| ファイル | 内容 |
|---|---|
| `rtl/uart_baud_gen.sv` | 位相アキュムレータ方式の 16x enable 生成器（チャネルごとに1個。restart で divisor をラッチ） |
| `rtl/uart_tx.sv` | 8N1 送信器。valid/ready 入力、`tx_busy` 出力（TEMT 用） |
| `rtl/uart_rx.sv` | 8N1 受信器。2FF 同期、中央サンプル、FE/BREAK、1クロックのイベント出力 |
| `rtl/uart_phy.sv` | TX と RX をまとめる薄いラッパー |
| `../../tb/unit/uart/tb_uart_phy.sv` | ビットレベル TB（DUT とは独立したデコーダとホストモデル） |
| `../../tb/unit/uart/uart_phy_tb.f` | Verilator 用 filelist（リポジトリ直下からの相対パス） |

詳細な仕様・設計判断・テスト項目は [`UART_DESIGN.md`](UART_DESIGN.md) を参照。
既存の `uart_ns16550`、core、top、`core.f` には**まだ接続していない**。FIFO、IRQ、16550 分割は次段階。

### 仕様の要点
- 8N1 固定（8 データビット、パリティなし、ストップ1、LSB first、idle High）。
- baud = `REF_HZ / (16 · divisor)`。`REF_HZ` の既定は 3,686,400（DTS の UART `clock-frequency` と同じ値）。
  例: DIV=2 → 115200、DIV=1 → 230400、DIV=27 → 8533.33。
- 生成クロックは作らない。`CLK_HZ`（50MHz / 20MHz を想定）から enable を作る。条件は `0 < REF_HZ < CLK_HZ < 2^31`。
- divisor は TX が転送時、RX が start 検出時にラッチする。divisor=0 の間は新規の送受信をしない（TX は ready Low、RX は armed をクリア）。
- RX の BREAK は 10 Tbit 以上の連続 Low でだけ確定する。それより短い Low stop は FE のみ。イベントはどちらでも1回で、data/FE/BI は揃って出る。
- 外部の `rxd` を除き、クロックドメインは1つ。RTL に DPI・`$write`・`$test$plusargs` は使っていない（パラメータ検査用に generate 内の `$error` だけがある）。

### 検証コマンド

まとめて実行する場合（既存の Docker イメージ `mints-linux-verilator:5.046` を使い、ログは `build/test/uart/` に出る）:

```sh
bash tools/test-de0cv-uart.sh
```

2026-11-09 の結果: RTL の lint（`-Wall`）は警告0、TB のビルドは 50MHz・20MHz とも警告0。
単体テストは両方で `UART_PHY_TB_PASS`（シミュレーション時間 279ms）。

個別に実行する場合のコマンド:

リポジトリ直下で実行する。出力は Git 除外の `build/` 配下に置く。

```sh
# 50 MHz
verilator --binary --timing --sched-zero-delay --assert --timescale 1ns/1ps \
  -f tb/unit/uart/uart_phy_tb.f --top-module tb_uart_phy -GCLK_HZ=50000000 \
  --Mdir build/test/uart/obj_50m -o tb_uart_phy_50m
build/test/uart/obj_50m/tb_uart_phy_50m

# 20 MHz
verilator --binary --timing --sched-zero-delay --assert --timescale 1ns/1ps \
  -f tb/unit/uart/uart_phy_tb.f --top-module tb_uart_phy -GCLK_HZ=20000000 \
  --Mdir build/test/uart/obj_20m -o tb_uart_phy_20m
build/test/uart/obj_20m/tb_uart_phy_20m

# RTL だけの lint
verilator --lint-only -Wall fpga/de0-cv/rtl/uart_baud_gen.sv fpga/de0-cv/rtl/uart_tx.sv \
  fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv --top-module uart_phy
```

合格条件: 両方のクロックで `UART_PHY_TB_PASS clk_hz=<N>` が出て、終了コードが0であること。
失敗は `$fatal`（非ゼロで終了）。watchdog はシミュレーション時間 1.5s。

Quartus での合成・Fit・STA、ピン割当、実機での echo は未実施で、この段階の範囲外。
