# G3: DE0-CV 実機 UART echo — 設計案（Codex のレビュー待ち）

作成: 2026-11-09 / Claude / 基準 `afa5a07`
**状態**: Codex のレビューで設計が決まり（11章）、RTL・TB・runner・ホストコードを作成した。**lint・コンパイル・シミュレーション・合成・実機への書込みは未実行**で、差分レビューを待っている。
**実機への書込みは、GPIO の 3.3V の根拠（4章）を一次資料で確かめるまで GO ではない**（書込みスクリプトは、根拠を記録した `fpga/de0-cv/uart_echo/GPIO_VOLTAGE_EVIDENCE.md` がないと止まる。確認が済んで記録した後は、追加の承認なしで通常どおり使える。`CONFIRM_GPIO_3V3=yes` は、記録ファイルができる前のレビュー済みセッション用の明示的な上書き）。
表記: **[確認]** 一次資料・コードで確認、**[推測]** 未検証の推論、**[未確認]** 実物や資料での確認が必要。

## 1. 目的と位置づけ
- 目的: CPU も SDRAM も使わずに、Mac から 115200 8N1 で送ったバイトを FPGA がそのまま送り返すこと。受信フレームの異常（FE/BREAK）とバッファ溢れは FPGA 側で診断できるようにする。
- 前提にする検証済みの部品: `fpga/de0-cv/rtl/uart_{baud_gen,tx,rx,phy}.sv`（PHY 単体）と、regs+PHY の結合（`afa5a07`、シミュレーションのみ）。
- **PHY だけの echo が PASS しても、Linux の UART が実機で PASS したことにはならない**。ここで確かめるのは、物理層（ピン、電圧、極性、baud、同期化、FE/BREAK の検出）と、ボード、ホスト、ツールの経路だけ。16550 レジスタ、IRQ、ドライバの経路は G5.5 以降のゲートで確かめる。

## 2. 方式の比較と推奨

| 案 | 構成 | 利点 | 負担・リスク |
|---|---|---|---|
| **A（推奨・G3a）** | `uart_phy` + 小さな echo FIFO（RX のイベントを push、TX へ pop） | 構成が最小で、失敗したときの切り分けが容易（ピン、baud、電気特性に集中できる）。CPU も Membus も不要 | 16550 のレジスタ、FIFO、LSR は実機で試されない |
| B（任意・G3b） | `uart16550_regs` + `uart_phy` + ハードウェア FSM（Membus マスタとして LCR/DLL/DLM/FCR を初期化し、LSR をポーリングして RBR を読み THR に書く） | regs の FIFO、LSR、divisor の経路を実機で動かせる | 新しい FSM（Membus のハンドシェイク、valid の保持、ready 待ち）を作って検証する必要があり、それ自体が新しいバグ源になる。FSM のバグと物理層のバグが混ざる |

- **決定**: G3 は案 A だけで合否を判定する。案 B（16550 のハードウェア FSM）は作らない。regs の実機動作は、G5.5（CPU + M10K ROM + UART）でソフトウェアがアクセスする形で確かめる。
- 注: **G5.5 は、共有の復旧計画（`Docs/MiNTs_DE0CV_M1_FPGA_Architecture_Recovery_Plan.md` の G0〜G11）にはない補助段階**で、前回のレビュー（`Docs/reviews/DE0_CV_PRE_IMPLEMENTATION_REVIEW.md`）で提案したもの。正式なゲートとして採用するかは、共有文書を改訂するときに決める。
- 未決定 U1: 案 B を G3b として実施するかどうか（Codex が判断）。

## 3. 構成（案 A）

```text
CLOCK_50 (PIN_M9) ─┬─ reset sync (KEY0) ── rst_n
                   │
 UART_RXD (PIN_M21, JP1-10) ─► uart_phy.rxd ─► rx_valid/rx_data/fe/bi ─┐
                                                                      ▼
                                                 echo_core: FIFO 16×8 + 診断
                                                                      │
 UART_TXD (PIN_K22, JP1-8) ◄── uart_phy.txd ◄── tx_valid/tx_data/tx_ready ┘
                   LEDR[9:0] ← 状態表示（HEX は使わない）
```

- クロック: `CLOCK_50`（PIN_M9）を直接使う。PLL は使わない。`CLK_HZ=50_000_000`、`REF_HZ=3_686_400`、**divisor は定数2**（= 115200）。PHY の位相アキュムレータで作るので、平均 baud は 115200.0 になり、各ビット境界の誤差は 1 clk（20ns）未満 [確認: PHY 単体 TB]。
- リセット: KEY0（PIN_U7、押すと Low）で非同期に assert し、2段 FF を通して同期的に解除する（blink と同じ方式）。PHY と echo_core に同じ `rst_n` を配る。`RESET_N`（PIN_P22）は FPGA の DEV_CLRN につながっているので使わない [確認: マニュアル表 3-2]。

### 3.1 echo FIFO（`uart_echo_core`）
- 深さ16、幅8。push は PHY の RX イベントで、**FE=0 かつ BI=0 のときだけ**行う（未決定 U2: FE/BI のバイトもエコーするか。推奨はエコーしない）。
- pop は `tx_valid = count != 0` と `tx_ready`（PHY）の転送で行う。
- **同時の push と pop**: push は `count_after_pop < 16` なら受理する（満杯でも同じサイクルに pop があれば受理）。受理できなかったバイトは捨て、overflow を sticky にし、回数を数える。
- **overflow の条件**: 同じ速度で送り続けるだけでは overflow しない。TX は RX イベントの直後に始まり、平均1バイトずつ追いつくので、16 バイトを超えたからといって溢れるわけではない。overflow が起きるのは、TX が止まっている（`tx_ready=0`）か、ホストの方が速くて差が累積した場合だけ。そのため overflow は core 単体 TB（`tx_ready=0` で 16+1 個投入、満杯と同時の pop/push）で検査し、top では検査しない。
- 速度の余裕 [推測/計算]:
  - RX のイベントは stop の中央（9.5 ビット）で出る。TX は次のクロックで開始でき、1フレームにかかるのは 10 ビット + 1 clk。
  - ホストの USB-UART の baud が FPGA より速いと、TX が少しずつ遅れる。例えば +0.16%（FT232R の 115384 baud）なら約 0.0016 バイト/バイトずつ溜まり、16 段が埋まるのは約1万バイトの連続受信の後。
  - 連続ストリームの試験量は 4 KiB にする。**4 KiB は試験量であって、無損失を保証する上限ではない**。無制限の連続 echo が無損失であるとは主張しない。
- 診断カウンタ（16bit、飽和）: `rx_ok_cnt`、`fe_cnt`（BI を除く）、`bi_cnt`、`ovf_cnt`、`tx_cnt`。sticky フラグ: `fe_seen`、`bi_seen`、`ovf_seen`。クリアは KEY0 のリセットだけ。

### 3.2 LED の表示（決定: HEX は使わない、LED だけ）

| 出力 | 意味 |
|---|---|
| LEDR0 | heartbeat（1Hz の点滅。0.5s ごとに反転） |
| LEDR1 | RX のアクティビティ（正常なバイトを受信したとき、約 50ms 点灯） |
| LEDR2 | TX のアクティビティ（同上） |
| LEDR3 | FE を検出した（sticky） |
| LEDR4 | BREAK を検出した（sticky） |
| LEDR5 | overflow が起きた（sticky） |
| LEDR6〜8 | 0 固定（初版の「RX line Low 監視」は削除した。生の RX から別の同期器を増やさないため） |
| LEDR9 | リセット解除済み |

ピン [確認: マニュアル表 3-4]: LEDR0..9 = AA2, AA1, W2, Y3, N2, N1, U2, U1, L2, L1。

## 4. 物理接続とピン（一次資料での照合）

一次資料: Terasic「DE0-CV User Manual」（2015-05-04 版、`https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5740/DE0_CV_User_Manual_112.pdf`、SHA-256 `a0db9405…a9055`。blink の README と同じ資料で、ローカルの `/private/tmp/mints-de0cv-manual.pdf` と一致）。

| 復旧計画 4.6 の記述 | マニュアルの図 3-12 / 表 3-7 | 判定 |
|---|---|---|
| JP1 | 図 3-12: 「(GPIO 0) JP1」 | [確認] JP1 = GPIO 0 |
| 8番 = FPGA TX | 8番 = `GPIO_0_D7` = **PIN_K22**（表 3-7 も `GPIO_0_D7 PIN_K22`） | [確認] |
| 10番 = FPGA RX | 10番 = `GPIO_0_D9` = **PIN_M21**（表 3-7 も `GPIO_0_D9 PIN_M21`） | [確認] |
| 12番 = GND | 12番 = GND（30番も GND） | [確認] |
| 11番 = 5V（使わない） | 11番 = VCC5、29番 = VCC3P3 | [確認] |

- 信号名: `UART_TXD`（FPGA の出力 → アダプタの RXD）、`UART_RXD`（アダプタの TXD → FPGA の入力）。
- I/O 規格: `3.3-V LVTTL` を設定した（blink の KEY/LED と同じ）[推測]。マニュアルの本文には、ヘッダに VCC3P3 があり、各ピンに保護ダイオードと抵抗がある（図 3-11）とだけ書かれ、GPIO バンクの VCCIO は明記されていない。**[未確認・継続]**: 一次資料の回路図、または Terasic 公式のリファレンス QSF（System CD / System Builder の出力）でバンクの電圧を照合する。**確認できるまでは実機への書込みは GO ではない**（qsf にもその旨を書いた）。
- RXD の弱プルアップ: `WEAK_PULL_UP_RESISTOR ON` にした。未配線のときに入力がフロートして偽の start を拾うのを防ぐ（決定）。
- 配線（ユーザーは 3.3V の USB-UART を準備済みで、まだ配線していない）:
  - 必ず電源を切った状態で配線する。
  - つなぐのは TX、RX、GND の3本だけ。アダプタの VCC（5V/3.3V）はつながない。
  - ピン1の位置は基板のシルクと図 3-12 で確かめる。
- アダプタ: ユーザーが 3.3V 品と明言しているので、改めての確認は必須にしない（Codex の判断）。型番と VID/PID は、ホストツールが実際のポートから検出して記録する。
- 注意 [推測]: FPGA の電源が切れている状態でアダプタの TXD（idle High）がつながると、保護ダイオード経由で電流が流れ込む可能性がある。ボードの電源を入れてからホスト側を開く手順にする。

## 5. Quartus プロジェクト（blink とは別プロジェクト）

- 場所: `fpga/de0-cv/uart_echo/quartus/de0_cv_uart_echo.{qpf,qsf,sdc}`。
- qsf: `5CEBA4F23C7`、`RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"`（blink と同じ）。ピンは 4章と 3.2 のとおりで、I/O 規格は 3.3-V LVTTL。
- **SDC**（例外は最小限にする）:
  ```tcl
  create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
  derive_clock_uncertainty
  # KEY0 は非同期で、リセット同期化器だけを駆動する（blink と同じ）
  set_false_path -from [get_ports {KEY0_N}] -to [get_registers {*reset_meta* *reset_n*}]
  # UART_RXD は非同期のシリアル入力で、PHY の RX 同期化 FF の1段目だけに入る
  set_false_path -from [get_ports {UART_RXD}] -to [get_registers {*u_rx|rxd_meta}]
  # UART_TXD: uart_tx の txd レジスタから直接ピンへ出す。ビット時間は 8.68us で、
  # 相手側にクロックの関係はないので、出力遅延は制約しない
  set_false_path -from [get_registers {*u_tx|txd}] -to [get_ports {UART_TXD}]
  # LED は人が見る表示で、タイミング要件はない
  set_false_path -to [get_ports {LEDR[*]}]
  ```
  - **コレクションが空だと例外は黙って無効になり、unconstrained の報告だけでは見つからないことがある**（Codex 指摘）。そのため、コンパイルの後に `quartus/check_constraints.tcl`（`quartus_sta -t`）で次を確かめ、1つでも外れたらビルドを失敗にする。
    - SDC が参照するコレクションの数を明示的に検査する（ポート KEY0_N/UART_RXD/UART_TXD 各1、LEDR 10、リセット同期レジスタ 2、`rxd_meta` 1、`rxd_sync` 1、`txd` 1）。
    - **同期器の段間（`reset_meta→reset_n`、`rxd_meta→rxd_sync`）は切らない**。そこに timing path が存在し、setup slack ≥ 0 であることを検査する。
    - 設計全体の worst setup/hold slack ≥ 0。
    - `report_ucp` の結果をファイルに保存する。
  - 同期器の各段（`reset_meta→reset_n`、`rxd_meta→rxd_sync`）は、**setup と hold の両方**について、timing path があり slack ≥ 0 であることを確かめる。
  - Quartus 20.1 の Tcl API（`get_timing_paths` のオプション、**`get_path_info` の引数の順序**（path を先に書き、次に `-slack`）、`qexit`）がこの書き方で動くかは未確認。最初に使う前に Quartus の help（`quartus_sta --tcl_eval help -cmd get_path_info` など）で確かめ、結果を記録する。
  - qsf・SDC・Tcl の中で `LEDR[0]` のようにバスの添字を含む名前は、すべて `{LEDR[0]}` のように brace で囲む（`[...]` を Tcl のコマンド置換として解釈させないため）。
  - `rxd_meta`/`rxd_sync` には `SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS"` を qsf で付けることを提案する（PHY の RTL は変えない）。
- TX 出力: `txd` は `uart_tx` の中のレジスタ出力で、組合せ論理を挟まずにピンへ出す。必要なら `FAST_OUTPUT_REGISTER ON` を検討する（任意）。
- ビルドと書込み: blink と同じ流れ（`tools/build-de0cv-blink-docker.sh` と `program-de0cv-blink.sh` にならう）。新しいスクリプト `tools/build-de0cv-uart-echo-docker.sh` と `tools/program-de0cv-uart-echo.sh` を作る。
- 合否を判断するレポート:
  - Fit の成功。
  - STA で setup/hold の slack ≥ 0。
  - unconstrained paths は上の例外以外に 0。
  - Pin-Out で K22=UART_TXD（出力）、M21=UART_RXD（入力、プルアップ）、3.3-V LVTTL。
  - ALM と レジスタの数を記録する。

## 6. 実機の前のシミュレーション
- `tb/unit/uart/tb_uart_echo_core.sv`（core 単体）:
  - `tx_ready=0` で 16 個受理し、17 個目で overflow の sticky とカウンタが立つ。
  - 満杯と同時の pop/push で受理され、順序が保たれる。
  - FE/BREAK は echo されずに数えられ、リセットでクリアされる。
  - カウンタが飽和する（`CNT_W=4` のインスタンスで確認）。
- `tb/unit/uart/tb_de0_cv_uart_echo.sv`（ボード top、50MHz、外部の実時間ホストモデル）:
  - リセット、LEDR9、heartbeat。
  - 単発と 256 値の back-to-back。
  - **短いストリーム（64 バイト）をホストの baud −2%/+2% で送り、受信の正確さと echo を確かめる**（無制限の連続無損失は主張しない）。
  - RX/TX のアクティビティ LED。
  - FE/BREAK で echo されず、LEDR3/4 が点灯し、その後のバイトは echo される。
  - KEY0 でクリアされる。
- ここが PASS してから Quartus でビルドする。

## 7. ホスト側の試験ツール（Mac）

- `tools/uart_echo_test.py`（Python 3、pyserial）。
- 依存の固定: `tools/requirements-uart-host.in` に `pyserial==3.5` を書く（`.gitignore` が `*.txt` を除外するため、拡張子は `.in` にした）。`tools/setup-uart-host-venv.sh` で `build/venv-uart/` を作る（`build/` は Git の対象外）。システムの Python には入れない。
- **ポートの指定**:
  - `--port /dev/cu.XXXX` を必須にし、自動選択はしない（指定がなければ一覧を表示して非0で終了する）。
  - 存在しないパスや `/dev/cu.*` 以外のパスは拒否する。
  - `serial.tools.list_ports` でそのポートの VID/PID/シリアル番号を記録する。`--expect-vid-pid` を指定した場合だけ照合し、一致しなければ中止する。指定しなければ記録だけして続ける（決定）。
  - Bluetooth などの別のポート（`/dev/cu.Bluetooth-Incoming-Port` など）は、名前に関係なく、明示的に指定されない限り使わない。
- **占有**: `serial.Serial(..., exclusive=True)` を使う。これは POSIX の**協調的な** flock で、同じくロックを取るプログラムとしか排他にならない。すべてのプロセスとの排他は保証しない。開けなければ中止する。screen などがすでに開いていても**強制終了はしない**。ユーザーが閉じる。
- 設定: 115200、8N1、フロー制御なし、`write_timeout` は 2s（4096 バイト ≈ 0.36s に対して十分）。**`write()` の戻り値は必ず送信長と比べる**。読出しは、全体の締切（`バイト数 × 10/115200 × 1.5 + 1s`）までの間、部分的な read を繰り返して溜める（1回の read の timeout は最大 0.5s）。開いたら `reset_input_buffer()`。
- 試験の項目（すべて全量を比較し、最初に不一致になった位置と前後のバイトを表示する）:
  1. 単発の `0x55` で往復する。
  2. 256 値を1つずつ（送信 → 1バイトを受信、タイムアウトあり）。
  3. chunk: seed を固定（既定 `20261109`）した 4096 バイトを 16 バイトの chunk で送り、毎回 echo を待ってから次を送る。
  4. 連続: seed を固定した 4096 バイトを一度に書き、`期待時間 × 1.5 + 1s` の締切までに全量を読んで比較する。
  5. 静止の確認: 最後に 0.5s 読んでも余分なバイトがないこと。
  6. （任意・診断）`send_break(0.25)` → echo なし。オペレータが LEDR4（bi_seen）の点灯を確かめる。KEY0 で消える。
- 出力: 日時、ポート、VID/PID/シリアル、baud、seed、各試験の送受信数と結果、PASS/FAIL を `build/logs/uart-echo-<日時>.log` に書く。終了コードは、すべて PASS なら0、それ以外は非0。

## 8. 実機の最終合格条件（G3a）
1. 5章のレポートの条件（Fit、STA の slack ≥ 0、unconstrained paths なし、ピン、I/O 規格、プルアップ）を満たし、レポートを保存している。
2. 書込み後に LEDR0 が点滅し、LEDR9 が点灯している。
3. 明示的に指定した実デバイスのポートで、`uart_echo_test.py` の試験 1〜5 が PASS し、終了コードが0。
4. 試験 1〜5 の後に LEDR3/4/5（FE/BI/overflow）が消えている（オペレータが確認する）。
5. 試験 6 で BREAK を送ると LEDR4 が点灯し、echo が返らない。KEY0 で消える。
6. 記録: Git のコミット、`.sof` の SHA-256、Quartus のバージョン、アダプタの型番と VID/PID、ホストのログ、LED の観察結果（必要なら写真）。
- これは「物理 UART の echo の PASS」であり、16550 や Linux の UART の PASS ではない。

## 9. 作成したファイル（2026-11-09、未実行）

| ファイル | 内容 |
|---|---|
| `fpga/de0-cv/uart_echo/rtl/uart_echo_core.sv` | FIFO 16、診断カウンタと sticky |
| `fpga/de0-cv/uart_echo/rtl/de0_cv_uart_echo.sv` | ボードの top（リセット同期、PHY、echo_core、LED） |
| `fpga/de0-cv/uart_echo/quartus/de0_cv_uart_echo.{qpf,qsf,sdc}` | 別プロジェクト |
| `fpga/de0-cv/uart_echo/README.md` | 配線、手順、合格条件 |
| `tb/unit/uart/tb_uart_echo_core.sv`、`uart_echo_core_tb.f` | core 単体 TB |
| `tb/unit/uart/tb_de0_cv_uart_echo.sv`、`de0_cv_uart_echo_tb.f` | ボード top の TB |
| `fpga/de0-cv/uart_echo/quartus/check_constraints.tcl` | コンパイル後の制約監査（コレクション数、同期段の timing、slack） |
| `tools/build-de0cv-uart-echo.sh` | コンテナ内のビルド（compile → check_constraints → RBF → SHA-256） |
| `tools/test-uart-echo-sim.sh` | 上の runner（Docker の Verilator） |
| `tools/build-de0cv-uart-echo-docker.sh`、`tools/program-de0cv-uart-echo.sh` | blink と同じ流れ。program は GPIO の 3.3V の根拠の記録（または明示的な上書き）、制約監査の PASS、JTAG の IDCODE を確かめてから SRAM に書く（フラッシュには書かない）。build は前回の出力を消さず、`build/fpga/archive/` に時刻付きで移す |
| `tools/uart_echo_test.py`、`tools/requirements-uart-host.in`、`tools/setup-uart-host-venv.sh` | ホストの試験 |

既存の CPU、Linux、`core.f`、blink のプロジェクト、Git は変更しない。

## 10. 未決定点
- U1〜U6: 決定済み（11章）。案 B は作らない。FE/BI はエコーしない。HEX は使わない。プルアップは ON。アダプタは記録のみ。TX は false_path。
- U7（継続）: GPIO バンクの VCCIO を、一次資料の回路図または Terasic 公式のリファレンス QSF で確認する。確認できるまで書込みは GO ではない。
- U8（決定）: 4 KiB は試験量で、無損失の上限ではない。ホストの baud 誤差の実測は、ポートの記録とあわせて任意で行う。


## 11. Codex レビューでの決定（2026-11-09）
- 案 A（PHY + 16 FIFO の echo）を採用。16550 のハードウェア FSM は作らない。
- FE/BI は echo せず、診断だけ。HEX は使わず LED だけ（最小構成を優先）。RX の弱プルアップは ON。
- アダプタはユーザーが 3.3V と明言しているので、改めての確認は必須にしない。型番と VID/PID は実際のポートから検出して記録する。`--expect-vid-pid` を指定しなくても止めない。
- TX の限定的な false_path は承認。実際のレポートで確かめる。
- 修正した条件:
  1. overflow の扱いと core TB（16+1、満杯+pop/push）。±2% は短いストリームの正確さとして扱う。4 KiB は試験量。
  2. write の戻り値の検査、全体の締切と部分 read。flock は協調的。他のプログラムを強制終了しない。
  3. LEDR6 の監視は削除し、LEDR6〜8 は 0。
  4. GPIO の 3.3V の根拠は確認を継続し、確認できるまで書込みは GO ではない。
  5. Tcl でコレクションの期待数を assert し、同期段は切らない。
  6. G5.5 は共有文書にない補助段階であることを明記。

## 12. 自己点検の注記
- `tools/uart_echo_test.py` は `python3 -m py_compile` で構文だけ確認した（テストは実行していない）。これ以外の lint・コンパイル・シミュレーション・合成は実行していない。
- 未確認:
  - Quartus が `SYNCHRONIZER_IDENTIFICATION` の `*u_rx|rxd_meta` のようなワイルドカードを受け付けるか。
  - `check_constraints.tcl` の API。
  - `async_reg` 属性の扱い（blink と同じで、Quartus では無視される可能性がある）。

## 13. 2回目のレビューを受けた修正（2026-11-09、未実行）
- qsf の `-to LEDR[0]`〜`[9]` と `LEDR[*]`、`check_constraints.tcl` の `"ports LEDR[*]"` を brace で囲んだ（Tcl のコマンド置換の防止）。他の Tcl も同じ観点で点検した。
  - SDC はもともと brace 付き。メッセージ内の `$what`/`$msg` は値として展開されるだけで、再評価はされない。
- 診断用カウンタは top では使っていないので、合成で除去される。実機での診断は sticky LED（LEDR3/4/5）であり、カウンタはシミュレーションで見るための出力だと明記した。SignalTap で保持できるとは主張しない。
- core TB の飽和検査を、5本すべてのカウンタ（rx_ok/fe/bi/ovf/tx）に広げた。`CNT_W=4` で 15 を超える事象を与え、`CNT_W=16` では正確な数（55/20/20/20/19）になることを確かめる。
- build は前回の出力を `build/fpga/archive/de0-cv-uart-echo-<UTC時刻>` に移す（失敗時のログを残すため）。
- program のガードは、根拠を記録した `GPIO_VOLTAGE_EVIDENCE.md` があれば通常どおり動く（実行のたびの承認は不要）。
- 制約監査で、同期器の各段の hold も確かめるようにした。`get_path_info` の引数の順序は、Quartus の help で確かめる必要があると記録した。
- GPIO の電圧を一次資料で確認することは、引き続き設計上の未決定事項（U7）。

## 14. 検証・合成の結果（2026-11-09、Codex の GO 後）

### 14.1 シミュレーション
- `bash tools/test-uart-echo-sim.sh`:
  - lint（`-Wall`、top `de0_cv_uart_echo`）は警告0。
  - core TB は 4/4 PASS（`UART_ECHO_CORE_TB_PASS`）。
  - top TB は 6/6 PASS（`DE0_CV_UART_ECHO_TB_PASS`、シミュレーション時間 35ms）。
  - ビルド警告は0、終了コードは0。
- 下記の修正 B の後に、関係する回帰をすべて再実行し、すべて終了コード0（ログは `build/test/reg_{phy,integ,echo}.log`）:

  | runner | 結果 |
  |---|---|
  | `tools/test-de0cv-uart.sh`（PHY 単体） | lint OK、50/20MHz とも `UART_PHY_TB_PASS` |
  | `tools/test-uart16550-phy.sh`（regs+PHY） | 50/20MHz とも 8/8 PASS |
  | `tools/test-uart-echo-sim.sh` | lint OK、core/top とも PASS |

### 14.2 Quartus の1回目の失敗と修正（Codex 承認済み）
- 失敗ログ: `build/fpga/failed-logs/echo-build1/`（`echo_build1.log`、`map.rpt`、`flow.rpt`）。
- **A: QSF の brace**:
  - `{LEDR[0]}` などを brace で囲んだ名前は、Quartus 20.1 の QSF 読み取りで brace ごと名前として扱われた。`Critical Warning (136021): Ignored assignment ... invalid node name` となり、LED の LOCATION と IO_STANDARD、同期器の指定が無視された。
  - 修正: QSF だけを Quartus/Terasic 標準の無 brace 形式に戻した。SDC と Tcl は brace のまま。
  - ガードを追加: `tools/build-de0cv-uart-echo.sh` は `136021`/`Ignored assignment` が1件でもあれば失敗する。さらに Pin-Out ファイルで、14本すべて（CLOCK_50、KEY0_N、UART_RXD/TXD、LEDR0〜9）の位置・方向・I/O 規格を照合する。
- **B: generate 内の `$error`**:
  - Quartus 20.1 Lite は、モジュール直下の generate-if の中の `$error` を構文エラーにした（`uart_baud_gen.sv:46`、`uart_echo_core.sv:40`）。
  - 修正: 両ファイルのパラメータ検査の generate ブロック全体だけを `// synthesis translate_off`/`on` で囲んだ。演算・状態・インタフェースは変更していない。
  - Verilator では検査が残ることを、不正なパラメータでの lint で確認した: `-GREF_HZ=60000000` と `-GDEPTH=12` で USERERROR が出て終了コード1、正常なパラメータでは0（`build/test/param-check/`）。
- **Tcl API**: Quartus 20.1 の help（`build/fpga/qhelp/sta_help.log`）で確かめた。
  - `get_path_info [-slack] <path_ref>` はオプションを先に書く形式なので、`get_path_info -slack $p` に修正した。
  - 監査をすべての operating condition（`get_available_operating_conditions`/`set_operating_conditions`/`get_operating_conditions_info -display_name`）に広げた。
  - 監査の条件は弱めていない。

### 14.3 2回目のビルド（成功）
- `bash tools/build-de0cv-uart-echo-docker.sh` は終了コード0。Quartus Prime 20.1.0 Build 711 Lite、デバイスは 5CEBA4F23C7。

| 資源 | 値 |
|---|---|
| ALM | 227 / 18,480（1%） |
| レジスタ | 270 |
| ブロックメモリ | 128 bit、M10K 1個（`uart_echo_core:u_echo\|mem_rtl_0`、16×8 が RAM として推論された） |
| ピン | 14 / 224 |
| DSP | 0 |

- **制約監査**（`check_constraints.log`、all checks passed）:
  - コレクション数は期待どおり: ポート KEY0_N/UART_RXD/UART_TXD 各1、LEDR 10、リセット同期 2、`rxd_meta` 1、`rxd_sync` 1、`txd` 1。
  - 同期器の段間（setup/hold）と、全体の worst slack（ns）:

  | コーナー | reset 段 setup/hold | RX 段 setup/hold | 全体 setup | 全体 hold |
  |---|---|---|---|---|
  | Slow 1100mV 85C | 18.891 / 0.517 | 18.304 / 0.918 | 12.034 | 0.363 |
  | Slow 1100mV 0C | 18.874 / 0.533 | 18.297 / 0.890 | 11.845 | 0.338 |
  | Fast 1100mV 85C | 19.453 / 0.272 | 19.082 / 0.477 | 16.162 | 0.181 |
  | Fast 1100mV 0C | 19.479 / 0.256 | 19.150 / 0.440 | 16.457 | 0.146 |

- **Unconstrained paths**: すべて0（`check_constraints_ucp.rpt`: illegal/unconstrained clocks、入出力ポート、ポートパスが setup/hold とも0）。CLOCK_50 は Constrained。
- **SDC の例外**: KEY0_N→リセット同期、UART_RXD→`rxd_meta`、`txd`→UART_TXD、LEDR[*] だけ。同期器の段間は timed のまま（上の表）。
- **Pin-Out**（ガードで照合済み。fit の Input/Output Pins でも確認）:
  - CLOCK_50=M9（3B）、KEY0_N=U7（3A）、UART_RXD=M21（5B、**Weak Pull Up On**）、UART_TXD=K22（5B、出力）、LEDR0〜9=AA2/AA1/W2/Y3/N2/N1/U2/U1/L2/L1（2A）。すべて 3.3-V LVTTL、位置はすべて User 指定。
  - fit の I/O Bank Usage では 5B が 3.3V になっているが、**これは自分たちの IO_STANDARD 設定から Quartus が導いた値で、基板の VCCIO の根拠ではない**。
- **警告の分類**（Critical Warning は0。2回目では 136021 は0件）:

  | 警告 | 件数 | 判断 |
  |---|---|---|
  | 10335 `async_reg` 属性を認識しない | 2 | 想定内。blink と同じ属性で、Quartus では無視される。同期器は qsf の SYNCHRONIZER_IDENTIFICATION で指定している |
  | 10036 `unused_busy` が読まれない | 1 | 想定内。未使用の busy をまとめた lint 対策の信号 |
  | 13024/13410 LEDR6〜8 が GND に固定 | 1（3ピン） | 設計どおり（0 固定） |
  | 276020 RAM の推論で pass-through を追加 | 1 | 想定内（同時の読み書きの挙動を保つため）。M10K 1個 |
  | 15714 出力ピンの drive strength と slew rate が未指定 | 1（11ピン） | 既定値を使用。LED と 115200bps の TX では問題ないと判断。必要なら次の改訂で明示する |
  | 292013 LogicLock はライセンスが必要 | 1 | Lite 版の情報。影響なし |

- **ハッシュ**（`build/fpga/de0-cv-uart-echo/quartus/output_files/sha256.txt`）:
  - `.sof`: `6917029bd705a061234679952eef06f4b5bdd07091e77317664a057c1a87d0cb`
  - `.rbf`: `02ba1c4c536e66650c4b3ca0aa5af4f8f001d63c6025a0861f341369a9044d74`
- 元の作業ツリー: `afa5a07` + 未コミットの G3 ファイル（Codex がコミットする前の状態）。

### 14.4 ホスト（read-only の確認だけ）
- `tools/setup-uart-host-venv.sh` で `build/venv-uart` を作り、pyserial 3.5 を入れた（`build/logs/uart-host-venv-setup.log`）。
- `uart_echo_test.py --help` は正常。`--port` なしでは一覧だけ出して終了コード2（自動選択はしない）。
- 列挙されたのは `/dev/cu.debug-console`、`/dev/cu.wlan-debug`、`/dev/cu.Bluetooth-Incoming-Port` だけで、USB-UART はまだつながっていない（未配線と一致）。シリアルポートは開いておらず、データも送っていない。

### 14.5 GPIO 電圧の一次資料（U7）: 未確認のまま
- Terasic の DE0-CV リソースページ（回路図と System CD の入手先）を取得しようとしたが、TLS 証明書の検証に失敗した。検証を無効にする取得は行わなかった。
- そのため、一次資料の回路図や公式 QSF による根拠は得られていない。**`GPIO_VOLTAGE_EVIDENCE.md` は作っていない**。
- 次の手段: ユーザーが Terasic から DE0-CV System CD（回路図 PDF、golden top QSF）を入手し、JP1（GPIO_0、バンク 5B）の VCCIO が 3.3V であることを確かめる。
- **実機への書込みと実 UART の試験は GO ではない**。`CONFIRM_GPIO_3V3` による上書きも使っていない。

### 14.6 Codex final review and programming checkpoint

Codex checked the regression logs, translate_off-only PHY change, pin guards,
constraint audit and unconstrained report. Accepted the simulation/Fit/STA results.
The prior U7 blocker is resolved using Terasic's published GPIO specification
and manufacturer FAQ; see `uart_echo/GPIO_VOLTAGE_EVIDENCE.md` for sources and
retrieval limitations. A schematic was not newly obtained and no voltage
measurement is claimed. User download/confirmation is not required for this point.

`bash tools/program-de0cv-uart-echo.sh` reached 100%, reported Done and exited 0.
Physical echo is still pending user wiring and the host test. Power-off wiring
clears SRAM configuration, so reprogram after the board is powered again.
