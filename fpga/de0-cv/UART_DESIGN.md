# DE0-CV UART 第1段階: 8N1 PHY と baud 生成器 — 設計・単体検証記録

更新日: 2026-11-09 / 作成: Claude（Orca worker）/ 管理・事前レビュー: Codex

> **状態**: Codex の実装前レビュー（`Docs/reviews/UART_PHY_DESIGN_REVIEW_CODEX.md`）は、2点の修正を条件に GO。
> 修正1（BREAK は10 Tbit 以上で確定）と修正2（divisor=0 中は armed をクリア）を `rtl/uart_rx.sv` に反映し、
> TB（`tb/unit/uart/tb_uart_phy.sv`）、filelist（`tb/unit/uart/uart_phy_tb.f`）、`README.md` を作成した。
> Codexの差分レビュー後、RTL lintと50MHz/20MHzのコンパイル・シミュレーションがPASS。
> Codexが修正内容と保存ログを確認済み。Quartusの合成・STA・実機確認は未実施。
> 既存の `uart_ns16550`/core/top/`core.f` には接続していない。
> この段階は「PHY 単体」であり、UART 全体（FIFO/IRQ/16550 分割/MMIO 接続/回帰/対話シェル）の完成を意味しない。
> 前回レビューの「送信欠落」（THRE 固定・TX FIFO なし）は、この PHY だけでは解決しない。

## 1. 範囲と非範囲

| 範囲（第1段階） | 非範囲（次段階以降） |
|---|---|
| 8N1 TX/RX ビットレベル PHY、16550 互換の baud 計算、ビットレベル TB | TX/RX FIFO（16段）、LSR/IIR/IRQ、FCR clear、OE、16550 レジスタとの分割 |
| 合成可能 RTL（DPI・`$write`・`$test$plusargs` なし） | DPI アダプタ、`core.f`/top への接続、DTS 変更、Quartus プロジェクト・SDC・ピン割当 |

8N1 限定。LCR の語長・パリティ・ストップビット設定には対応しない（16550 に直結する段階でも 8N1 固定と明記する）。

## 2. ファイル構成と API

### 2.1 `uart_baud_gen`（チャネルごとに1個、TX と RX が別インスタンス）

| ポート | 方向 | 意味 |
|---|---|---|
| `clk`, `rst_n` | in | システムクロック、負論理の非同期リセット |
| `restart` | in | 同期パルス。位相と分周カウンタを0にし、`divisor` をラッチする |
| `divisor[15:0]` | in | DLL/DLM 相当。restart のときだけ取り込む |
| `tick16` | out | 16x オーバサンプルの enable（**組合せ出力**。この値が1のサイクルの次の立上りが tick 時刻） |
| `divisor_latched[15:0]` | out | ラッチ済みの divisor（観測用。TX/RX では未接続） |

パラメータ: `CLK_HZ`（既定 50,000,000。20,000,000 も想定）、`REF_HZ`（既定 3,686,400 = 現 DTS の UART `clock-frequency`）。

アルゴリズム:
- `acc += REF_HZ`。`acc + REF_HZ >= CLK_HZ` のとき `acc -= CLK_HZ` として基準 enable を1回出す（位相アキュムレータ）。基準 enable `divisor` 回ごとに `tick16` を出す。
- baud = REF_HZ / (16·divisor)。例: DIV=2 → 115200、DIV=1 → 230400、DIV=27 → 8533.33。CPU clk を基準と混同しない。
- restart 後の n 番目の基準 enable は、エッジ ceil(n·CLK_HZ/REF_HZ) に来る（restart エッジ = 0）。各 tick の理想時刻からの遅れは [0, 1) clk で、**誤差は蓄積しない**（整数切捨てをしない）。
- 幅: `ACC_W = $clog2(CLK_HZ)+1`。`acc < CLK_HZ` かつ `acc+REF < 2·CLK ≤ 2^ACC_W` なのでオーバーフローしない。`sub_cnt < div_q` は不変条件（restart で0、div_q はフレーム中一定）。

reset/restart の仕様:
- `rst_n` Low: `acc=0`、`div_q=0`、`sub_cnt=0` → tick なし。
- `restart` High: 次エッジで `acc=0`、`sub_cnt=0`、`div_q=divisor`。restart 中は `tick16=0`。
- `div_q==0`: 生成器は停止し、tick を出さない。次の restart まで保持する。
- restart なしで `divisor` が変わっても影響はない（フレーム途中の cfg 変更に対する保護）。
- パラメータ検査: `0 < REF_HZ < CLK_HZ < 2^31` でなければ、generate 内の `$error` でエラボレーションを止める。

### 2.2 `uart_tx`

| ポート | 意味 |
|---|---|
| `divisor[15:0]` | 転送エッジでラッチ（内部 baud_gen の restart = 転送） |
| `tx_valid`, `tx_data[7:0]`, `tx_ready` | バイト入力ハンドシェイク |
| `txd` | シリアル出力（登録出力、idle High） |
| `tx_busy` | フレーム中（start〜stop 終了）。TEMT = FIFO 空 && !tx_busy |

ハンドシェイク契約:
- `tx_valid && tx_ready` が両方 High の立上りでだけ1バイト転送し、`tx_data` を取り込む。それ以外の valid/data は送らない。
- `tx_ready = rst_n && (state==IDLE) && (divisor!=0)`。valid には依存しない組合せ出力。転送の次サイクルから、stop ビット終了まで Low。
- 転送1回 = フレーム1つ。転送後も valid を High に保つのは「次のバイトの提示」を意味する。重複送信を避けるには、マスタが転送の次サイクルに valid を下げるか、次のデータに替える。

状態遷移（`IDLE → START → DATA×8 → STOP → IDLE`）:
- IDLE で転送が起きると: `txd←0`、`shreg←tx_data`、`os_cnt=0`、`bit_idx=0`、START へ。
- busy 中は `tick16` ごとに `os_cnt++`。`os_cnt==15` かつ tick でビット終了:
  - START → DATA（`txd←d0`、右シフト）
  - DATA は `bit_idx<7` なら次のビット。`bit_idx==7` なら STOP（`txd←1`）
  - STOP → IDLE

タイミング（Tbit = 16·div/REF_HZ、t0 = 転送エッジ）:
- start の立下りは転送エッジそのもの。
- 境界 k（1..10）はエッジ ceil(16·div·k·CLK/REF) で、t0+k·Tbit から [0,1) clk 遅れる。境界10 = stop 終了 = busy の立下り。
- back-to-back では、次の start は stop 終了エッジから1クロック後（ready の立上りを見て次エッジで転送）。stop 長は1ビット以上（+1 clk 以上）。
- `divisor` は転送時にラッチする。フレーム中に別の値や0に変えても、そのフレームは最後まで出る。0 のときは新規転送をしない（ready Low、txd High）。
- `rst_n` Low（非同期）: 送信中でも即 `txd=1`、IDLE、ready Low。

### 2.3 `uart_rx`

| ポート | 意味 |
|---|---|
| `divisor[15:0]` | start 検出エッジ E0 でラッチ |
| `rxd` | 非同期入力（2FF 同期。同期 FF のリセット値は **0**） |
| `rx_valid` | 1クロックのイベント（ready なし。消費側は止められない） |
| `rx_data[7:0]`, `rx_frame_err`, `rx_break` | rx_valid と同じエッジで更新し、次のイベントまで保持 |
| `rx_busy` | フレーム受信中 |

arm と start 検出:
- IDLE 中かつ divisor≠0 のとき、同期後の line が High なら `armed=1`。リセット直後は同期 FF=0、armed=0 なので、Low のまま保持されている line を start と誤認しない。
- **divisor==0 の間は、毎サイクル `armed=0`**（Codex 修正2）。無効中に見た High は start の資格として残らない。
- `start_cond = IDLE && armed && !rxd_sync && divisor!=0` で E0 を決め、baud_gen を restart（divisor をラッチ）する。
- したがって有効化した後は、High（divisor≠0 で1 clk 以上）を観測し、続いて Low になって初めて start とみなす。Low の途中で有効化しても、その Low を start として受理しない。
- 制約（残る挙動）: 他機器がフレームを送っている途中で有効化すると、そのフレーム内の High→Low 遷移を start と見なしうる。これは一般の UART と同じで、idle 中に有効化することを推奨する。

サンプリング（16x の中央で1サンプル）:
- START: 8 tick 後（半ビット）に再確認。High ならグリッチとして棄却（イベントなし）、IDLE（armed=1）へ戻る。
- DATA: 16 tick ごとに中央をサンプルし、`shreg={rxd_sync, shreg[7:1]}`（LSB first）。
- STOP: 16 tick 後に stop をサンプルし、イベントを出して IDLE へ。stop 中央で戻るので、次の start まで半ビットの余裕がある。
- サンプルエッジは E0 + ceil((8+16n)·div·CLK/REF)。E0 は line のエッジから 2〜3 clk 後（同期2段＋検出1サイクル）。この遅れは補正していない。

FE / BREAK / 再アーム:
- `rx_frame_err` = stop サンプルが Low。
- 判定（Codex 修正1）。開始1回につきイベントは1回で、data/FE/BI は同じエッジで出す。
  1. stop サンプルが High → stop 中央でイベント（FE=0, BI=0）。
  2. stop サンプルが Low、かつ E0 以降に一度でも High を観測（`saw_high`）→ stop 中央でイベント（FE=1, BI=0）。
  3. stop サンプルが Low、かつ E0 以降ずっと Low（data=0x00）→ 状態 `RX_BRK` に入り、この時点ではイベントを出さない。
     - a. 10 Tbit（E0 から 160 tick）より前に High を観測 → **High を観測したエッジ**でイベント（data=0x00, FE=1, BI=0）。
     - b. エッジ E0+ceil(160·div·CLK/REF) までずっと Low → そこでイベント（data=0x00, FE=1, BI=1）。
- BREAK には、同期後の line で E0 から 10 Tbit 以上の連続 Low が必要。line 時間に直すと、Low ≤ 10 Tbit なら必ず FE のみ、Low ≥ 10 Tbit+2 clk なら必ず BREAK。その間の約 2 clk 幅は同期位相次第（TB の境界テストはこの幅を避けて −2 clk / +3 clk で行う）。
- 通常フレームの受信は従来どおり stop 中央で確定する（ケース1）。
- 再アーム: 最後の観測が Low で終わったイベント（ケース2 で Low stop、ケース3b）の後は armed=0 のまま。line が1 clk 以上 High（divisor≠0）になるまで再アームしない。Low を保持し続けてもイベントは1回だけ。ケース1と3aは High で終わるので、すぐに armed=1 になる。
- 状態遷移: `IDLE → START →(glitch: IDLE) → DATA×8 → STOP → IDLE | BRK → IDLE`。
- `rst_n` Low: フレームを破棄（イベントなし）。再開には同期後の High の観測が必要。

### 2.4 `uart_phy`
`uart_tx` と `uart_rx` をまとめる薄いラッパー。`divisor` は共有するが、ラッチとフレーム時刻は TX と RX で独立している。

## 3. 設計判断（レビューしてほしい点）

1. **baud_gen をチャネルごとに持ち、フレーム開始で restart する**: 本物の 16550 は BRG を1個共有し、自由に回し続ける。本案では TX/RX ごとに位相を開始エッジに合わせるので、次の利点がある。(a) TX の全ビット長が理想グリッドから [0,1) clk に収まる。(b) RX のサンプル点が E0 基準で決まり、検証が容易。(c) divisor をフレームごとにラッチでき、途中の変更で壊れない。代償はアキュムレータ2本分の面積（27bit×2 程度、推測）。
2. **tick16 を組合せ出力にする**: 登録出力にすると、start ビットだけ1〜2 clk 長くなる。組合せ経路は「27bit 加算＋比較＋16bit 減算比較」で、50MHz では問題ないと推測（STA は未実施）。減算比較 `sub_cnt == div_q-1` は、restart 時に `div_q-1` をラッチすれば短くできる（未適用）。
3. **TX の back-to-back に 1 clk のギャップがある**: ready を組合せで tick16 に依存させないため。stop は常に1ビット以上になり、仕様上は問題ない。
4. **RX は中央1サンプル（多数決なし）**: スタートビットは半ビットで再確認する。データビットのノイズ耐性を上げたければ、3サンプル多数決（tick 7/8/9）を追加候補とする。
5. **BREAK の定義**（Codex 修正1で変更）: 「E0 から 10 Tbit 以上連続 Low」。10 Tbit 未満で High に戻る 0x00＋Low stop は FE のみ。FE のみのケース3a では、イベントの時刻が stop 中央ではなく High を観測した時点になる。
6. **E0 の 2〜3 clk 遅延は補正しない**: 20MHz・DIV=1（1ビット ≈ 86.8 clk）でサンプル点が約 3.5% 後ろへずれる。±3% の baud 差と合わせても、bit7 と stop の余裕は 20% 以上（計算による推測）。
7. **`tx_ready` に `rst_n` を組合せで含める**: リセット中に ready=1 が見えて、マスタがバイトを失うのを防ぐ。
8. **最大 baud**: REF=3.6864MHz では DIV=1 の 230400 が上限。921600 にするには REF_HZ（例 14.7456MHz < CLK_HZ）と DTS の変更が必要で、次段階で判断する。

## 4. 確認済みの事項と残る懸念点

- `ACC_W'(CLK_HZ)` 形式のサイズキャストと、generate 内の `$error` を Quartus Lite 20.1 が受け付けるか不明。受け付けなければ、ビット選択への置換や検査の `ifdef` 化を検討する。
- 未接続の`divisor_latched`は観測信号へ接続し、その宣言のみUNUSEDSIGNALを抑制した。
  RTLの`-Wall` lintは警告0。WIDTHやcaseに関する警告も出ていない。
- RX の同期 FF に、Quartus の synchronizer 識別属性と SDC の false_path をまだ付けていない（ボード層で設定する予定）。
- リセット解除の同期化はこの PHY の範囲外。上位（`de0_cv_top`）でリセットシンクロナイザが必要。
- RX: divisor 0→非0 で Low 途中の誤 start は修正2で解消（TB R9）。他機器のフレーム途中で有効化した場合の扱いは 2.3 の制約のまま。
- RX ケース3a: High が 10 Tbit 直前に戻ると、その直後の新しい start とイベントが近接する。line が High を出した後の Low は IDLE（armed=1）から通常どおり検出される。
- TBはVerilator 5.046で動作確認済み。可変遅延が0になる場合には
  `--sched-zero-delay`を指定する。TB全体の`-Wall`とミューテーションは未実施。
- RX: 2FF 前の 1 clk 未満のグリッチは見えないことがある（正常動作）。

## 5. テスト設計（50MHz / 20MHzでPASS）

構成: `tb/unit/uart/tb_uart_phy.sv`（`` `timescale 1ns/1ps ``、パラメータ `CLK_HZ`）と `tb/unit/uart/uart_phy_tb.f`。

推奨コマンドは`bash tools/test-de0cv-uart.sh`（Docker利用）。
直接実行する場合はリポジトリ直下で以下を使う。出力はGit除外の`build/`配下:

```sh
verilator --binary --timing --sched-zero-delay --assert --timescale 1ns/1ps \
  -f tb/unit/uart/uart_phy_tb.f --top-module tb_uart_phy -GCLK_HZ=50000000 \
  --Mdir build/test/uart/obj_50m -o tb_uart_phy_50m && build/test/uart/obj_50m/tb_uart_phy_50m
# 20 MHz: -GCLK_HZ=20000000, obj_20m / tb_uart_phy_20m
verilator --lint-only -Wall fpga/de0-cv/rtl/uart_*.sv --top-module uart_phy
```

DUT: `u_tx`、`u_rx`（ホスト線で駆動）、`u_phy`（txd→rxd ループバック）、`u_bg`（baud_gen 単体）。それぞれ独立したリセットと divisor を持つ。

参照モデルの独立性:
- TX の検査はリアルタイムのシリアルデコーダで行う。t0 からの `#((i+0.5)·Tbit)` でサンプルし、Tbit = 16·div·1e9/REF_HZ ns の数式だけを使う。DUT と同じアキュムレータは使わない。
- RX はホスト送信タスクが `#Tbit_host` の実時間で line を駆動する。

### 5.1 baud_gen 単体
- DIV=1,2,27,65535 で、tick i の発生エッジ番号 n が `0 ≤ n − i·div·CLK/REF < 1` を満たす（i=1..64、65535 は i=1..2）。
- 計数中に divisor を変えても周期が変わらない（ラッチ）。DIV=0 では tick が出ない。連続 restart で位相が再開する。

### 5.2 TX
1. div=0 で valid を保持しても、ハンドシェイク・立下りが0回、ready Low、txd High。
2. 基本: 0x00/0xFF/0x55/0xAA/0x01/0x80 をデコードして一致、stop 中央 High、stop が1ビット以上（t0+10·Tbit まで次の立下りがない）。フレーム内のエッジ数がデータから期待される遷移数と一致（グリッチ検出）。
3. タイミング: 0x55 で9本の境界エッジを捕捉し、各エッジの偏差が [0, Tclk)（±2ps）。平均ビット長 (e9−t0)/9 と baud を表示・検査。busy の立下りが t0+10·Tbit+[0,Tclk)。DIV=1/2/27/256、50MHz・20MHz の両方で行う。
4. back-to-back: 次の t0' − (t0+10·Tbit) ∈ [Tclk, 2·Tclk)。32 バイトのランダム列を valid 保持のまま送り、順序・個数が一致。
5. valid/ready の無関係な揺らぎ: busy 中に valid/data を毎サイクルランダムに変えても、ハンドシェイクで取り込んだバイトだけが順に出る。
6. cfg 変更: フレーム途中で DIV 2→27 にしても、そのフレームは DIV2 のグリッドのまま。次のフレームは DIV27。途中で 0 にした場合、そのフレームは完了し、以後は ready Low で送信なし。
7. リセット中断: フレーム途中で rst_n を下げると、1ps 以内に txd=1・busy=0・ready=0。解除後に残りが出ない。その後の正常送信が一致。
8. 常時アサーション: ready→!busy、ready→div≠0、転送直後のサイクルは ready=0、!busy→txd=1。

### 5.3 RX（期待キュー：data/FE/BI/line 立下り時刻/RX の Tbit）
- イベント時刻の検査（観測は rx_valid を立てた次の posedge）:
  - stop 中央で確定するイベント: 観測時刻 − line 立下り ∈ [9.5·Tbit+3·Tclk, 9.5·Tbit+5·Tclk]（2FF と検出遅延を考慮した中央サンプルの確認）。
  - BREAK: 観測時刻 − 立下り ∈ [10·Tbit+3·Tclk, 10·Tbit+5·Tclk]。
  - BRK 待ち中の FE: 観測時刻 − line の High 復帰 ∈ [3·Tclk, 4·Tclk]。
1. DIV=2: 全256値 back-to-back と、ランダム間隔＋ps 単位の非同期位相の 64 フレーム。
2. ±3%: DIV=2 で全256値を +3%/−3% それぞれ back-to-back。DIV=1 は全256値（公称）と ±3% のサブセット、DIV=27 は 32 値。
3. グリッチ: 幅 0.4·Tbit、1·Tclk、0.37·Tclk → イベントなし。その後の正常フレームを受信。
4. FE: 0xA5＋stop Low → (A5, FE=1, BI=0)。次の正常フレームを受信。
5. BREAK のしきい値（DIV=2）。各ケースの後に正常フレームを受信できることも確認する。
   - Low 9.3 Tbit → 正常な 0x00（stop 中央は High）。
   - Low 9.7 Tbit → FE のみ。
   - Low 10 Tbit−2 clk → FE のみ。
   - Low 10 Tbit+3 clk → BREAK。
   - Low 25 Tbit → BREAK が**1回だけ**。
6. FE 後に Low を保持（30·Tbit）→ イベント1回。High 後に正常受信。
7. cfg 変更: フレーム途中で DIV 2→1 にしても完了。途中で 0 にしてもそのフレームは完了し、その後の DIV=0 中のフレームは無視。idle 中に DIV=2 へ戻すと正常受信。
8. リセット: フレーム途中で中断（イベントなし）。line Low のまま reset を解除しても誤イベントなし。High 後に正常受信。
10. 無効中の Low 途中での有効化（修正2）:
    - (a) DIV=0、idle High → Low → Low の最中に DIV=2 → 20 Tbit 間イベントなし → High → 正常フレーム受信。
    - (b) DIV=0 で 0xF0 を送信中、d0（Low）の途中で DIV=2 → そのフレームはイベントなし → 直後の back-to-back フレーム 0x5A を正常受信。
    - 旧草案（armed が残る）ではどちらも偽イベントで `$fatal` になるので、修正の有無を判別できる。
9. 常時チェック: rx_valid は連続2サイクル立たない。BI なら FE=1 かつ data=0。期待キューが空のときにイベントが来たら即 `$fatal`。

### 5.4 ループバック（u_phy）
- DIV=2 と DIV=1 で、0..255 を valid 保持のまま送り、受信が順序どおり一致し FE/BI=0。**ループバックだけを正しさの根拠にはしない**（5.2/5.3 が主）。

### 5.5 終了条件
- watchdog: シミュレーション時間 1.5s（見積り総量は約 0.25s、推測）で `$fatal`。待ちループにはそれぞれクロック数の上限を設ける。
- 失敗はすべて `$fatal(1, ...)`（非ゼロで終了）。成功時は `UART_PHY_TB_PASS clk_hz=<N>` と、検証範囲・未実施項目の一覧を表示する。

### 5.6 この TB で扱わないもの
- FIFO・IRQ・16550 レジスタ・DPI アダプタ。
- 実ボードの電気特性・ピン。
- Quartus での合成・Fit・STA。
- 長時間のランダム化（seed は固定）。
