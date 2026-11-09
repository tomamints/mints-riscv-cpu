# UART regs + PHY 結合検証計画（ビットレベル）

作成: 2026-11-09 / 実装: Claude / 検証前レビューと GO: Codex
Git の基準: `32302dc`（clean）

> **状態**: TB・filelist・runner を作成済み。**lint・コンパイル・シミュレーションは未実行**（Codex の差分レビューと GO を待つ）。
> 範囲は新規 `rtl/peripheral/uart16550_regs.sv` と、検証済みの `fpga/de0-cv/rtl/uart_phy.sv`（`uart_baud_gen`/`uart_tx`/`uart_rx`）の結合だけ。
> `src/uart_ns16550.sv`、`core.f`、CPU、C テスト、Linux、Makefile、ボード、Git は変更しない。
> これに PASS しても SoC・Linux・実機の動作確認にはならない。

## 1. ファイル

| ファイル | 内容 |
|---|---|
| `tb/unit/uart/tb_uart16550_phy.sv` | 結合 TB（パラメータ `CLK_HZ`） |
| `tb/unit/uart/uart16550_phy_tb.f` | filelist（eei、membus_if、regs、PHY 4ファイル、TB） |
| `tools/test-uart16550-phy.sh` | runner（Docker の Verilator 5.046。50MHz と 20MHz でビルドして実行。ログは `build/test/uart-integ/`） |

## 2. 接続（TB 内で直結。既存 RTL は変更しない）

| regs | 接続先 | 備考 |
|---|---|---|
| `rst`（負論理） | PHY の `rst_n`（負論理） | 同じ信号。極性は一致 |
| `divisor` | `uart_phy.divisor` | TX/RX で共用。DLAB 中の TX 停止は regs の `tx_valid` 側で行う |
| `tx_valid`/`tx_data` → | `uart_phy.tx_valid/tx_data` | |
| `tx_ready` ← | `uart_phy.tx_ready` | PHY の ready は tx_valid に依存しない（組合せループなし） |
| `tx_busy` ← | `uart_phy.tx_busy` | TEMT 用 |
| `rx_push/rx_data/rx_fe/rx_bi` ← | `uart_phy.rx_valid/rx_data/rx_frame_err/rx_break` | 1 クロックのイベント |
| `rx_space` | **未接続** | PHY は止められないので使わない。満杯なら OE |
| `txd` | 外部 TX デコーダ | |
| PHY `rxd` | 外部 RX ドライバ（`host_line`） | |

パラメータ: `CLK_HZ` = 50,000,000 / 20,000,000（`-G` で切替）、`REF_HZ` = 3,686,400。基本は divisor 2（115200）。

## 3. 独立性とタイミングの規約
- **MMIO**: Membus BFM を使う。valid を negedge で出し、受理と rvalid がそれぞれ1回であることを検査して、negedge で戻る。期待値は仕様（`UART_REGS_DESIGN.md`）から手で書いた。
- **TX の検査**: txd の立下りで起動する外部デコーダが、`t0 + (i+0.5)·Tbit` の実時間で10ビットをサンプルする。
  - stop 中央が High であること、フレーム内のエッジ数がデータから期待される遷移数と一致すること（グリッチの検出）、次の立下りまで1 Tbit 以上あること（stop 長）を確かめる。
  - Tbit は **TB が書いた divisor の値**（`host_tx_div`）から計算する。DUT の内部信号は見ない。デコーダはフレームの開始時に `host_tx_div` をラッチする。
  - `host_tx_div` は、新しいフレームが始まりえない DLAB 中に更新する。これにより「送信中のフレームは旧 divisor、DLAB を外した後のフレームは新 divisor」を仕様どおりに表現できる。
  - `host_tx_div == 0` のときに start bit が来たら、strict かどうかに関係なく即 `$fatal` にする。
- **フレームの数え方**（Codex 指摘で修正）: 新しいフレームの有無は `dec_start_cnt` で判定する。これはデコーダが**待機中（line が idle）に start と認定した**時点で +1 するカウンタ。
  - `expect_no_tx_start`（新しいフレームが始まらないこと）と `wait_tx_starts_since`（フレームが始まるまで待つ）は、このカウンタだけを使う。進行中のフレームのデータ内の立下りは数えないので、フレームの途中から監視を始めても誤判定しない。
  - `txd_raw_fall_cnt` はデータ内も含めたすべての立下りを数える生のカウンタ。用途は、デコーダ内部の stop 長の検査（stop 中央のサンプルから t0+10·Tbit−EPS まで立下りがないこと）だけに限る。フレーム数の計数には使わない。`txd_edge_cnt` は全エッジ数で、フレーム内のグリッチ検査用。
  - **デコーダが見落とす期間はない**:
    - start の後、デコーダは t0+10·Tbit−EPS まで占有される。その間の立下りのうち、stop 中央のサンプルより前のものはフレームの一部として、エッジ数の比較で検査する（strict では余分なエッジは `$fatal`）。stop 中央から t0+10·Tbit−EPS の間のものは、stop 長の検査で `$fatal` にする。
    - t0+10·Tbit−EPS からは再び `@(negedge txd)` で待つ。正しい次の start は PHY の back-to-back の間隔により t0+10·Tbit+Tclk 以降なので、取りこぼさない。
    - reset 中（rst=0）は txd が High に固定されるので、start は発生しない。
    - `dec_strict=0` にするのは、`t_reset` (b) で送信途中に意図的に reset する前後だけ。その間は途切れたフレームを検査しないが、計数は続ける。
- **RX の駆動**: 外部ドライバが `host_rx_div` から Tbit を計算し、clk と非同期の位相（+0.37 Tclk）で実時間に line を駆動する。
- **race 回避**: posedge のプロセスは計数だけを行う（受理数、rvalid 数、txd のエッジ数）。刺激の変更・キューの検査・判定はすべて negedge か実時間で行う。
  - デコーダは立下りから 2ps 待ってからエッジ数を読む（同じ時刻の計数プロセスと競合しないため）。
  - フレーム開始の待ちは、THR 書込みの**前に**数えた立下り数を基準にする（書込み中に開始しても取りこぼさない）。

## 4. カバレッジ表（50MHz と 20MHz の両方で実行）

| 要求（Codex の指示） | テスト | 主な検査 |
|---|---|---|
| 基本 115200 の TX/RX | `t_basic` | OpenSBI と同じ初期化手順（DLAB→DLL/DLM→LCR=3→FCR=1→MCR=0）。TX 5バイト（0x00/0xFF/0x55/0xA5/'H'）を実シリアルでデコード、RX 5バイトを RBR で読む。LSR=0x60、IIR=0xC1、診断0 |
| TX 16 FIFO（順序、THRE/TEMT/IRQ） | `t_tx_fifo16` | IER=2 で THRE IRQ、IIR 読出しでクリア。1フレームの送信中に17バイト書き込み（PHY に1、FIFO に16）、溢れなし。書込み後は LSR=0x00。最後のバイトを handoff したときに irq=1、LSR=0x20（THRE=1、TEMT=0）、IIR=0xC2。17 フレームの順序、stop 終了後に LSR=0x60 |
| divisor 変更: 送信中は旧 divisor で完了、DLAB 中は新しいフレームを止める、更新後に開始 | `t_divisor_change` | DIV=2 のフレームの途中で DLAB=1、DLL=1。10 Tbit 待っても新しい start がない。最初のフレームは DIV=2 でデコードできる。LCR=3 の後のキュー内バイトは DIV=1（230400）でデコードできる。RX も新しい divisor で受信 |
| RX 連続16 + overrun、RBR の排出、OE のクリア | `t_rx_overrun` | 17 フレームを back-to-back で送る。diag_rx_overrun=1、IIR=0xC6（OE による RLS）、LSR=0x63（読出しで OE クリア）、IIR=0xC4、RBR で 16 バイトを順に読む、LSR=0x60、IIR=0xC1 |
| FE/BI と RLS > RDA > THRE | `t_fe_bi_priority` | 0xA5 を Low stop で送る（FE）、25 Tbit の Low（BREAK）、通常の 0x5A。IIR と LSR の順: C6/E9/C4、RBR=A5、C6/F9/C4、RBR=00、LSR=61、RBR=5A、IIR=C2（THRE が最後）、C1 |
| FCR clear: 送信中のフレームは完走し、未送信分だけ破棄 | `t_fcr_clear` | 5バイトを書き、最初のフレームの途中で FCR=0x05。LSR=0x20、0x11 だけが完全にデコードされ、15 Tbit 待っても次の start がない、その後 LSR=0x60 |
| RX clear 直後の受信 | `t_fcr_clear` | 3バイト受信後、受信中の 0x77 のフレームの途中で FCR=0x03。clear の後に 0x77 が1つだけ残る |
| reset 中・送受信途中の reset で旧データを破棄 | `t_reset` | (a) reset 中に host が送ったバイトは残らない（LSR=0x60、IIR=0x01）。再初期化後に受信できる。(b) TX フレームの途中で非同期 reset → 1ps 以内に txd=High、キュー内のバイトは出ない、LSR=0x60、再初期化後に送信できる。(c) RX フレームの途中で reset → イベントなし、再初期化後に受信できる |
| divisor 0 で停止、復帰 | `t_divisor_zero` | divisor=0 では TX が開始しない（20 Tbit）、LSR=0x00（データ保持）。**外部の host は無効中も通常の速度（`host_rx_div=2`、115200）で送り続ける意図で**フレームを送り、PHY の RX がそれを無視すること（LSR.DR=0）を確かめる。divisor=2 に戻すと保持していた2バイトが送信され、RX も受信する |
| rx_space が実 PHY を止めない | 構造 | `rx_space` は未接続。overrun は `t_rx_overrun` で確認 |
| リセット極性の統一 | 構造 | 同じ `rst` を regs の `rst` と PHY の `rst_n` に接続 |

## 5. 仕様上の穴・適用時の注意（報告）
1. **reset 後の divisor は 0**: regs のリセットで DLL/DLM=0 になり、PHY は送受信しない。`t_reset` (c) の「RX 途中の reset で旧データを破棄」は、reset 後に divisor=0 であることも効いて成立する。reset の解除後すぐに divisor≠0 で受信を始める経路（PHY の rearm だけによる保護）は、PHY 単体 TB の R10 で確認済みで、この結合 TB では再確認していない。
2. **DLL と DLM の書込みの間の RX**: TX は DLAB で止まるが、RX は divisor を直接使う。DLL だけ書いた中間値（例: 上位が古いまま）の間に始まった受信フレームは、誤った速度で受ける。仕様どおり（16550 も同じ）だが、結合 TB では検査していない。
3. **reset で送信中のフレームが途切れる**: 相手側から見ると不完全なフレーム（FE の可能性）になる。仕様どおりで、TB はそのフレームを検査対象から外している（`dec_strict=0`）。
4. **THRE 割込みの時刻**: THRE は最後のバイトを PHY に渡した時点（送信開始時）に立ち、TEMT は stop の終了時に立つ。16550 と Linux の想定どおり。
5. **BREAK 中の RX**: PHY は 10 Tbit で BI のイベントを1回出し、High に戻るまで再アームしない。FIFO にはエントリが1つ入る。
6. **適用できないケース**: なし。ただし「reset 中」の検査は、regs と PHY が同じ reset を共有する前提である（FPGA の top でも同じにする必要がある）。

## 6. 実行予定（未実行）
```sh
bash tools/test-uart16550-phy.sh
```
- 合格条件: 50MHz と 20MHz の両方で `UART16550_PHY_TB_PASS clk_hz=<N>` が出て、終了コードが0。
- ビルドフラグは PHY 単体 TB と同じ `--binary --timing --sched-zero-delay --assert --timescale 1ns/1ps`。TB は可変の `#` 遅延を使うので、ZERODLY 警告への対処として前例と同じ指定にした。
- 見積り: シミュレーション時間は約 6〜8ms（50MHz で約40万サイクル）[推測]。watchdog は 200ms。

## 7. 懸念点
- Verilator で次が受理されるか未確認: `initial` 内の `forever` と `continue`、`#(EPS)`、可変長キューを引数に取るタスク、fork 内でのバス操作。
- 20MHz・DIV=1 では1ビットが約86.8 clk しかない。`t_divisor_change` の「DLAB 中の 10 Tbit」は旧 DIV=2 の Tbit で測っているので余裕がある。
- `t_tx_fifo16` で THRE IRQ を待つ間の最初のバイトの handoff により、一度 pending が立ち、次の THR 書込みで消える。書込みの途中で irq が一瞬 1 になるのは仕様どおりで、検査は全書込みの後に行う。
- 修正履歴（2026-11-09、Codex 指摘）: 初版の `expect_no_tx_start` と `wait_tx_starts_since` は生の立下り数を使っていた。そのため、`t_divisor_change`（0x55 の約2ビット後から監視）と `t_fcr_clear`（9.5 ビットでキューに入った直後から監視）では、正常なデータ内の立下りで必ず誤判定していた。いずれも `dec_start_cnt` に変えた。
- 外部デコーダは中央サンプルとエッジ数で判定する。ビット境界の時刻精度（<1 clk）は PHY 単体 TB で検証済みなので、ここでは再検査しない。

## 8. 実行結果（2026-11-09、Codex の GO 後）

- コマンド: `bash tools/test-uart16550-phy.sh`（Docker `mints-linux-verilator:5.046`）。ログは `build/test/uart-integ/`。
- **1回目: ビルド失敗**（ログは `build/test/uart-integ/failed-run1/` に保存）。
  - 原因: TB の `uart_init` で、16bit の `div` を 32bit の TB 変数 `host_tx_div`/`host_rx_div` に代入しており、WIDTHEXPAND 警告が2件出た（既定で fatal）。
  - 修正: `host_tx_div = 32'(div); host_rx_div = 32'(div);` と明示的にキャストした。値も意味も変わらない、TB の幅だけの修正。RTL は変更していない。
- **2回目: runner の終了コード0**。

| CLK_HZ | ビルド警告 | 結果 | sim 時間 |
|---|---|---|---|
| 50,000,000 | 0 | 8/8 グループ PASS、`UART16550_PHY_TB_PASS clk_hz=50000000`、終了コード0 | 6ms |
| 20,000,000 | 0 | 8/8 グループ PASS、`UART16550_PHY_TB_PASS clk_hz=20000000`、終了コード0 | 6ms |

- PASS したグループ: basic 115200 の TX/RX、TX FIFO 16 の THRE/TEMT/IRQ、divisor の変更、RX 16+overrun、FE/BI と優先度、FCR の TX/RX clear、reset（保持中、TX 途中、RX 途中）、divisor 0 の停止と復帰。
- 未確認の範囲:
  - sim backend（DPI）での置き換えと `core.f` への接続。
  - CPU から MMIO 経由での動作、既存 C テストと Linux の回帰。
  - FPGA での合成（regs の M10K/ALM、組合せ経路の STA）、ピン・電気特性、実機の USB-UART。
  - DLL と DLM の書込みの間の RX 中間 divisor（5章2）、reset 解除直後の divisor≠0 での RX（5章1）。
- 位置づけ: これは G3（実機 UART の echo）の前提となるシミュレーション上の結合確認であり、実機での UART 動作の PASS ではない。次のゲートは、ボード echo の設計レビュー。
