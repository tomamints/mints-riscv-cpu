# UART 第2段階: 16550 レジスタ/FIFO の分割と PHY 接続 — 設計案（Codex レビュー反映版）

作成: 2026-11-09 / Claude（Orca worker）/ 実装前レビュー・GO 判断: Codex
基準: 作業ブランチ `cd781f9`（PHY 単体のシミュレーションは Codex 受入れ済み）

> **状態**: Codex レビュー（`Docs/reviews/UART_REGS_DESIGN_REVIEW_CODEX.md`）の判断を反映した改訂版。regs RTL の実装はまだ GO ではない。
> 先行作業として、テスト基盤の復元（`tb/sw/common/`、Makefile の変数化）と、現 RTL での基準記録（`fpga/de0-cv/UART_C_TEST_BASELINE.md`）だけを行った。
> **主な改訂**: FIFO は物理的に16段だが、FCR[0]=0 の間の有効容量は1（16450 相当）とする。初版の「FCR[0] に関係なく常に16段」案は不採用。
> 第1段階の PASS は「8N1 PHY 単体の Verilator シミュレーション」だけを意味する。
> SoC への接続、OpenSBI/Linux での動作、実機の UART 動作はいずれも未検証で、この案の実装後に別ゲートで確認する。
>
> 表記: **[確認]** はコードや一次資料を読んで確認したこと、**[推測]** は未検証の推論、**[提案]** は本案の設計判断。

## 0. 根拠にした資料

| 資料 | 場所 | 用途 |
|---|---|---|
| 現 UART モデル | `src/uart_ns16550.sv`（311行） | 現在の挙動と Membus 契約 |
| SoC 接続 | `src/top.sv:495-502`（インスタンス）、`:645-646`（lockstep） | ポートと `tx_char_valid` の用途 |
| DPI 入力 | `tb/tb_verilator.cpp:44-53` `get_input_dpic()`（stdin を毎回 1byte `read()`） | sim の RX 供給元 |
| OpenSBI v1.3.1 | `build/external/opensbi/lib/utils/serial/uart8250.c`（`git describe` = v1.3.1） | 初期化手順と putc |
| Linux v6.12 8250 | GitHub `torvalds/linux` v6.12 の `drivers/tty/serial/8250/{8250_port.c,8250_of.c,8250_early.c}` と `serial_core.c`（scratchpad に取得し読み取りのみ） | probe、startup、THRE テスト、FIFO 書込み |
| DTS | `platform/riscv_cpu.dts:51-61`（`ns16550a`、clock 3.6864MHz、IRQ 10、reg-io-width 1） | ドライバの型の決定 |
| 既存テスト | `core/test/uart_*.c`、`Makefile:229-353` | 回帰対象 |

## 1. API・ソース配置・sim/FPGA の分離（項目1）

### 1.1 ブロック構成 [提案]

```text
                 Membus.slave (既存契約そのまま)
                        │
          ┌─────────────▼──────────────┐
          │ uart16550_regs (合成可能)   │  RBR/THR/IER/IIR/FCR/LCR/MCR/LSR/MSR/SCR/DLL/DLM
          │  TX FIFO 16 / RX FIFO 16    │  irq 出力, divisor[15:0] 出力
          └──┬───────────────────────┬─┘
     tx byte stream             rx byte event (+fe,+bi)
  (tx_valid/tx_data/tx_ready)  (rx_push/rx_data/rx_fe/rx_bi, readyなし)
             │  tx_busy               │  rx_space (DPI専用の参考出力)
   ┌─────────┴─────────┐   ┌──────────┴─────────┐
   │ sim backend (DPI)  │   │ FPGA: uart_tx/uart_rx │ ← 検証済み PHY
   │ $write / get_input │   │ (fpga/de0-cv/rtl)     │
   └────────────────────┘   └───────────────────────┘
```

| ファイル（新規） | 合成 | 内容 |
|---|---|---|
| `rtl/peripheral/uart16550_regs.sv` | 可 | レジスタ、FIFO、IRQ、Membus slave。DPI・`$write`・`$test$plusargs` は入れない。sim 用 assert は `` `ifdef MINTS_SIM `` で囲む |
| `rtl/peripheral/uart_fifo.sv`（任意） | 可 | 16段 FIFO（幅パラメータ）。regs の内部に書いてもよい |
| `src/uart_sim_backend.sv` | 不可（sim 専用） | DPI 入力、`$write` 出力、`TRACE_*` 表示 |
| `src/uart_ns16550.sv`（**置換**） | 不可 | 既存のモジュール名とポート（`clk, rst, membus, irq, tx_char_valid, tx_char`）を保つ sim ラッパー = regs + sim backend |
| `fpga/de0-cv/rtl/uart16550_phy_top.sv` | 可 | regs + `uart_tx` + `uart_rx`（FPGA 用。`txd`/`rxd` のピン） |

- **`top.sv` は変更しない**（ポート互換のため）。`core.f` には `rtl/peripheral/uart16550_regs.sv`（と `uart_fifo.sv`）、`src/uart_sim_backend.sv` を `src/uart_ns16550.sv` より前に追加するだけにする。
- FPGA 用 filelist（将来の `fpga/de0-cv/soc.f`）では `src/util.sv`、`src/uart_ns16550.sv`、`src/uart_sim_backend.sv` を除き、`uart16550_phy_top.sv` を使う。CPU 側の `core_top` を FPGA で使うには、`top.sv` の sim 依存（`memory.sv` の DPI、debug MMIO の `$write`）を分ける別作業が必要。これは本案の範囲外（前回レビュー指摘12）。
- リセット: SoC は負論理の `rst`、PHY は負論理の `rst_n` で極性は同じ。クロックは1つ（PHY の `CLK_HZ` = SoC クロック）。

### 1.2 `uart16550_regs` のポート [提案]

| ポート | 方向 | 意味 |
|---|---|---|
| `clk`, `rst` | in | 負論理の非同期リセット（SoC と同じ） |
| `membus` | slave | 既存の `Membus`（64bit データ、バイトレーン） |
| `irq` | out | レベル出力。PLIC の source 10 へ |
| `divisor[15:0]` | out | `{DLM, DLL}`。TX と RX で共用（DLAB 中の TX 停止は tx_valid 側で行う） |
| `tx_valid`, `tx_data[7:0]` | out | TX FIFO 先頭。`tx_valid = (tx_count != 0) && !LCR[7] && !tx_clear_accept`。DLAB 中と、TX FIFO をクリアする FCR 書込みを受理するサイクルには handoff しない。**この規則は regs の内部で保証するので、sim backend にも PHY にも同じように効く**。MCR loopback では止めない（6.3） |
| `tx_ready` | in | backend/PHY が1バイト受け取る（転送 = valid && ready の立上り） |
| `tx_busy` | in | PHY がフレームを送信中（TEMT 用）。sim backend は 0 固定 |
| `rx_push`, `rx_data[7:0]`, `rx_fe`, `rx_bi` | in | 1クロックの受信イベント（**ready なし**） |
| `rx_space` | out | `rx_count_after_pop < cap`。**DPI backend だけが使う**。PHY は見ない |
| `diag_tx_overflow`, `diag_rx_overrun` | out | sticky（リセットでだけクリア）の診断出力。THR 書込みの破棄と RX バイトの破棄 |

## 2. FIFO と FCR（項目2）

### 2.1 FIFO [Codex 判断で確定]
- TX: 物理 16 段 × 8bit。RX: 物理 16 段 × {data[7:0], fe, bi}（10bit）。カウンタは 5bit（0..16）。
- **有効容量** `cap = FCR[0] ? 16 : 1`。FCR[0]=0 の間は TX/RX とも 16450 相当（holding register 1 段）として振る舞う。`FCR[0]`、`IIR[7:6]`、実際の容量を常に一致させる。
  - TX: `tx_count < cap` なら THR 書込みを受理する。そうでなければ破棄し、診断を出す（3章）。
  - RX: `rx_count_after_pop < cap` なら push を受理する。そうでなければ OE（5章）。
- 初版の「常に16段」案は不採用。理由（Codex レビュー）:
  - Linux 6.12 の `serial8250_console_write()` が FIFO 経路を選ぶ条件は、ソフトウェア上の FCR だけでなく `port->state`、`TTY_PORT_INITIALIZED`、port lock も含む。
  - `serial8250_clear_and_reinit_fifos()` はクリア後に FCR を設定し直す。
  - `clear_fifos()` の一部の手順だけを根拠に「常に16段が必要」とは言えない。
- Linux で欠落などの問題が出た場合は、仕様を変える前に、FCR への実際のアクセス列とシリアル出力を採取して原因を確かめる。

### 2.2 FCR の対応範囲 [Codex 判断で確定]

| ビット | 扱い |
|---|---|
| 0 FIFO enable | 保存し、IIR[7:6]=`{2{fcr0}}` と有効容量に反映。**値が変わったら TX/RX 両 FIFO をクリア**（TI TL16C550C の FCR 説明に従う） |
| 1 RX clear | **書込み後の FCR[0]=1 のときだけ**有効。自己クリア。RX FIFO、エラー数、head 表示/ack をクリア（OE はクリアしない） |
| 2 TX clear | 書込み後の FCR[0]=1 のときだけ有効。TX FIFO をクリアし、**受理エッジでは PHY への新しい handoff を出さない**。送信中のフレームは止めない |
| 3 DMA mode | 無視 |
| 5:4 | 予約。無視 |
| 7:6 RX trigger | 書込み後の FCR[0]=1 のときだけ保存する（FCR は書込み専用なので読み返しはない）。**動作には反映しない**。RDA は1バイト以上で立つ（トリガ1固定）。文字タイムアウト（IIR 0x0C）は実装しない。これは暫定の対応範囲として明記する |

- FCR[0]=0 を書いた場合、clear/trigger などの他のビットは無視する。enable の切替によるクリア（1→0）だけは効く。
- RX clear と新しい push が同時なら、クリアの後に新しいバイトを1つ残す。enable の切替によるクリアと push の同時も同じ扱い。

## 3. THRE / TEMT / TX 満杯（項目3）

- `LSR.THRE (bit5) = (tx_count == 0)`。**FIFO（または FCR[0]=0 なら holding）が完全に空**のときだけ 1（"not full" ではない）。
  根拠 [確認]: Linux の `serial8250_tx_chars` は1回の THRE 割込みで LSR を見ずに最大 `tx_loadsz=16` バイト書く（:1790-1816）。console も THRE 待ちの後に16バイト書く。
- `LSR.TEMT (bit6) = (tx_count == 0) && !tx_busy`（Codex 判断で確定。handoff_pending のような未接続の状態は追加しない）。handoff は同期の valid/ready（`tx_valid && tx_ready` の立上り）で行う。そのエッジで `tx_count` が減り、PHY の `tx_busy` が立つので、TEMT に空白サイクルは生じない [確認: uart_tx は転送エッジで busy]。sim backend は `tx_busy=0`。
  - Linux の console write は最後に `BOTH_EMPTY`（THRE|TEMT）を待つ [確認: 8250_port.c:3401]。TEMT が早く立つと、直後の FIFO クリアやボーレート変更で末尾の文字が壊れる。
- **TX 満杯（`tx_count == cap`）での THR 書込み**: そのバイトは捨てる（16550 でもデータは失われる）。黙って成功扱いにはしない。sim では `` `ifdef MINTS_SIM `` の `$error` を出す。合成版には sticky な `tx_overflow` 診断出力（LED/デバッグ用。レジスタには見せない）を出す。FCR[0]=0 なら cap=1 なので、THRE を見ずに2バイト書けば2バイト目で溢れる。
- MCR loopback は保存するだけなので、**MCR[4] では tx_valid を止めない**（Codex 判断）。
- TX 満杯でも、同じサイクルに pop があれば THR 書込みを受理する（pop 後の数 `tx_count_after_pop < cap` で判定）。

## 4. IRQ / IIR（項目4）

### 4.1 割込み源と IIR [提案]

| 優先度 | IIR[3:0] | 条件 | 解除 |
|---|---|---|---|
| 1 | 0x6 RLS | `IER[2] && (OE \|\| head_err_visible)` | LSR 読出し（OE と表示中のエラーを消す） |
| 2 | 0x4 RDA | `IER[0] && rx_count != 0` | RX FIFO が空になる |
| – | 0xC timeout | **実装しない**（2.2） | – |
| 3 | 0x2 THRE | `IER[1] && thre_pending` | 4.2 |
| 4 | 0x0 MSI | 常に 0（モデム線なし） | – |
| – | 0x1 | 割込みなし | – |

- `IIR[7:6] = {fcr0, fcr0}`、`IIR[5:4] = 0`。
- `irq = (IER[2] && rls) || (IER[0] && rda) || (IER[1] && thre_pending)`。レベル信号で、PLIC gateway の扱いは既存のまま。
- 既存テストとの整合 [確認]: `core/test/uart_regs.c:40` はリセット直後の IIR を `0x01`、`uart_tx_irq.c:77` は THRE 割込み中の IIR を `0x02` と期待している。現 RTL（`uart_ns16550.sv:53` は常に `0xc0|...`）とは食い違っており、FCR[0] を IIR[7:6] に反映する本案ならこの2つと一致する。

### 4.2 thre_pending の更新規則（1サイクルにつき）[Codex 判断で確定]

1. **書込み後の IER を優先して判定する**。今サイクルの IER 書込みを反映した値で ETBEI=0 なら、`thre_pending_next = 0`（他の事象に関係なく）。
2. ETBEI=1（書込み後）の場合:
   - set 事象:
     - `tx_fifo_becomes_empty`: 今 `tx_count>0` で次 `tx_count==0`。pop、TX clear、enable の切替によるクリアを含む。
     - `ier_etbei_rise`: IER 書込みで ETBEI が 0→1、かつ書込み後に `tx_count==0`。
   - clear 事象:
     - THR 書込み。
     - IIR 読出しで、その読出しが THRE（0x2）を返したとき。
   - `thre_pending_next = set | (thre_pending & ~clear)`。新しい空遷移や enable の事象は、IIR 読出しによる clear に勝つ。IIR は更新前の状態を返すので、同時に起きた事象は報告されていない。
3. THR 書込みと最後の1バイトの pop が同時（count=1 で push と pop）なら、FIFO は空にならないので set しない。THR 書込みの clear だけが効く。
4. バスは1サイクルに1アクセスなので、THR/IER 書込みと IIR 読出しは互いに排他。同時に起こりうるのは「バスアクセス」と「PHY/backend の pop」の組合せだけ。
5. ETBEI=0 の間に FIFO が空になっても pending は 0 のまま（規則1）。後で ETBEI 0→1 にしたとき、FIFO が空なら set する。

- Linux の要件 [確認]:
  - (a) THRE 再アサートの probe（8250_port.c:2310-2345）: `IER=THRI → IIR 読出し → IER=0 → IER=THRI → IIR 読出し`。2回目も THRE が出ないと `UART_BUG_THRE` 扱いになる。規則1（IER=0 で 0）と規則2（0→1 で set）で満たす。
  - (b) TXEN テスト（:2386-2399）: `IER=THRI` の直後に LSR と IIR を読み、`TEMT && IIR==NO_INT` なら `UART_BUG_TXEN`。IER 書込みの次のアクセスで IIR に反映されていること（同期で1サイクル後なら十分）。
  - (c) `__start_tx` は `serial8250_set_THRI` が IER を 0→1 に変えたときだけ割込みに頼る（:1522-1529）。

### 4.3 RX の同時 push/pop と clear [提案]
- push は `rx_base < cap_next` なら受理する。`rx_base` = クリアがあれば 0、なければ `rx_count_after_pop`。`cap_next` = このサイクルの FCR 書込み後の容量（16 または 1）で、**クリア時は新しい容量を使う**。満杯で同時に pop があれば受理し、OE は立てない。
- push と RX clear（FCR）が同時なら「clear の後に push」とし、新しいバイトを1つ残す。
- push と FCR0 の変化によるクリアが同時なら、上と同じ扱い。
- RBR 読出しの pop と push が同時なら、count は変わらず、head は進む。

## 5. FE/BI のバイト付随、OE、LSR のクリア（項目5）[提案]

- **RX FIFO の各エントリに `fe`、`bi` を持たせる**。PHY のイベント（第1段階で data/FE/BI が同時に出る）をそのまま格納する。BREAK は data=0x00、fe=1、bi=1 の1エントリになる。
- `LSR.DR (0) = rx_count != 0`。
- `LSR.OE (1)`: sticky。push を受理できなかったとき（`rx_count_after_pop >= cap`）に set。**LSR 読出しで clear**（読んだ値には 1 が見える）。LSR 読出しと新しい overrun が同時なら、**新しい overrun が勝つ**（OE=1 のまま）。捨てたバイトは FIFO に入れない。FCR[0]=0（cap=1）では、未読の1バイトがある間に次が届けば OE。
- `LSR.PE (2) = 0`（パリティなし）。
- `LSR.FE (3)` / `LSR.BI (4)` [Codex 判断で確定: エントリ付随 + head ack]:
  - 各エントリが原フラグ `fe`、`bi` を持つ（FIFO 内では変化しない）。
  - `head_err_ack`: **現在の head** に対する ack。LSR 読出しの受理エッジで 1 にする。head が変わるとき（pop、空の FIFO への push、クリア）は 0 にする。**同じエッジで LSR 読出しと head の変化が起きたら、新しい head は ack を継承しない（0）**。LSR が返した値は古い head のものだからである。
  - `FE = DR && head.fe && !head_err_ack`、`BI = DR && head.bi && !head_err_ack`。`head_err_visible = DR && (head.fe|head.bi) && !head_err_ack`（RLS 割込みの条件、4.1）。
  - Linux との整合 [確認]: `serial_lsr_in()` は LSR を読むとエラービットを `lsr_saved_flags` に退避し、`serial8250_read_char`（:1686-1730）で次の文字と合わせて使う。LSR 読出しで表示を消しても情報は失われない。BI のときは FE/PE を無視し、break として数える（:1709-1711）。
- `LSR.FIFOE (7)` [改訂: head ack との関係を明記]:
  - `rx_err_count` = FIFO 内で原フラグ（fe|bi）を持つエントリの数。push で +1、pop で -1、クリアで 0。
  - `unacked_err = rx_err_count - ((DR && (head.fe|head.bi) && head_err_ack) ? 1 : 0)`。
  - `LSR.FIFOE = FCR[0] && (unacked_err != 0)`。
  - 意味: 「まだ LSR で報告していないエラーが FIFO 内に1つ以上ある」。TI の「LSR 読出し時に、後続のエラーが FIFO 内になければクリアされる」に対応する。
    - head だけがエラーなら、LSR を読んだ時点で FE/BI の表示も FIFOE も 0 になる。
    - head 以外にもエラーがあれば、FIFOE は 1 のまま残る。
    - エラーを持つエントリが head に来ると FE/BI が表示され、ack は 0 から始まる。
  - FCR[0]=0（16450 相当）では常に 0（TI の 16450 モードの定義）。
  - 確認すべき点: 原フラグとの関係は `rx_err_count`（原フラグの数）と head_ack の差で決まり、エントリのフラグそのものは書き換えない。
- 代替案（不採用）: 生のフラグをそのまま表示し、読出しで消さない。

- RBR が空のとき（DR=0）の読出しは `0x00` を返し、pop しない。現 RTL は古い FIFO 内容を返すが、`uart_regs.c:62` は 0x00 を期待している。

## 6. divisor / LCR / 8N1 / DLAB / MCR loopback（項目6）

### 6.1 レジスタとバイトレーン [確認・現状維持]
- レジスタ番号は `addr[2:0]`（バイト間隔、`reg-shift=0`、`reg-io-width=1`）。データは `wdata[addr[2:0]*8 +: 8]` で、`wmask[addr[2:0]]=1` のときだけ書込みが有効（`uart_ns16550.sv:37-42,167-172`）。読出しはそのレーンに置き、他は 0（`:65-68`）。
- `addr[7:3]` は無視し、窓（0x100）の中で 8 バイトごとに繰り返す（現状どおり、DTS の reg 長と一致）。
- 副作用（RBR pop、IIR による THRE clear、LSR clear）は、アドレス指定されたレジスタにだけ起こす。幅の広いロード（lw/ld）でもアクセス先は `addr[2:0]` の1本だけ（現状どおり）。

### 6.2 DLL/DLM/LCR [提案]
- `LCR` は 8bit を全部保存して読み返すが、動作に使うのは `LCR[7]`（DLAB）だけ。**8N1 固定**: 語長・ストップ・パリティ（LCR[5:0]）は無視する。LCR[6]（break 送出）も未対応。OpenSBI も Linux も `LCR=0x03`（8N1）を書く [確認: uart8250.c、8250_port.c:2353]。
- `divisor = {DLM, DLL}`。リセット値は 0（現状どおり。PHY は送受信しない）。
- **TX の divisor ゲート**（推奨案 A）: `tx_divisor = LCR[7] ? 16'd0 : {DLM,DLL}`。DLL と DLM を順に書く間（DLAB=1）は新しいフレームを始めないので、途中の divisor 値（例 DLL だけ新しい）でフレームを送ることがなくなる。フレーム中の値は PHY 側でラッチされる。
  - RX は `{DLM,DLL}` を直接使う（ゲートすると DLAB 中の受信を落とすため）。このため FPGA の top では `uart_phy` ラッパーを使わず、`uart_tx`/`uart_rx` を個別にインスタンスする。
  - 案 B: ゲートしない（16550 と同じ）。単純だが、DLL と DLM の書込みの間に始まったフレームは誤った速度になる。
  - **Codex 判断: 案 A を採用**。これは 8N1 向けの実装判断として明記する（16550 は DLAB 中も送信を続ける）。送信中のフレームは旧 divisor のまま完了する。RX の divisor 更新と組み合わせた試験を行う（11.1）。
- `IER` は下位4bit だけ保存し、上位は 0 で読める（現 RTL `:191`、16550 仕様）。`uart_regs.c:43-44` は IER=0x55 の読み返しを期待しており、**16550 仕様とも現 RTL とも合わない**。テスト側を 0x05 に直す提案（要承認）。

### 6.3 MCR / MSR [提案]
- `MCR` は 5bit（bit0..4）を保存して読み返す（上位は 0）。`uart_regs.c:46-47` の 0x1b と一致する。
- loopback（MCR[4]）:
  - **Codex 判断: 今回の範囲外（案 B）**。保存だけで、送受信・モデム線のループバックはしない。**未対応機能として明記し、NS16550 の全機能互換は主張しない**。Linux の固定型 probe に加え、このボードのドライバ設定（DTS `ns16550a`、OpenSBI の MCR=0）を前提にする。Linux は `ns16550a` の probe で `UPF_FIXED_TYPE` が付くため（8250_of.c:109、:322）、`serial_core.c:2608-2616` で `UART_CONFIG_TYPE` が立たず、loopback を使う `autoconfig` は走らない [確認]。OpenSBI は MCR=0 を書く [確認]。
  - 案 A: TX FIFO の出力を RX FIFO へバイト単位で折り返し、`tx_valid=0`、MSR を `{DCD=OUT2, RI=OUT1, DSR=DTR, CTS=RTS}` にする。regs を PHY なしで自己試験できるが、範囲が広がる。
  - `uart_regs.c` は MCR=0x1b（loopback ビットあり）にした後で 'R' と '\n' を送るが、出力の確認はしていない [確認]。案 B なら文字はそのまま出力される（現状と同じ）。
- `MSR = 0x00`（モデム線なし、現状どおり）。`SCR` は読み書き可。

## 7. Membus の契約（項目7）[確認・維持]
- 既存の契約をそのまま引き継ぐ（`uart_ns16550.sv:35,100,121-131`）。
  - `ready = !bus_wait_valid_low`。
  - 受理は `valid && ready` の立上り。
  - 受理した次のサイクルに、**読み書きとも** `rvalid` を1回出す。
  - 受理後は `valid` が一度 Low になるまで `ready=0`。
- これにより、マスタ（`mmio_controller`）が `valid` を保持していても、同じ要求を二度受理しない。副作用（pop、clear）は受理エッジでだけ、1回起こる。
- `mmio_controller` は受理（ready を見た）次のサイクルから `rvalid` を見るので、受理と同じサイクルの応答は禁止（前回レビュー C3）。現状の1サイクル後の応答を保つ。
- 未確認のリスク: コアが MMIO ロードを発行した後に取り消して再発行する経路（例外・割込みでのフラッシュ）があると、RBR の pop が二重になる。`memunit` が MMIO ロードを取り消すかどうかは今回読み切れていない。RX の対話回帰（11.3）で、入力した文字が失われたり重複したりしないことを確認する。

## 8. DPI backend と FPGA backend（項目8）[提案]

### 8.1 sim backend（`src/uart_sim_backend.sv`）
- **TX**: `tx_ready = 1` で、毎サイクル FIFO 先頭を1バイト pop して `$write("%c")` と `$fflush()` を行う。`tx_busy = 0`。
  - 出力は backend の pop 時の1か所だけにする。regs は `$write` しない。
  - `tx_char_valid`/`tx_char` は pop イベントから作る（1クロックのパルス）。lockstep の `lockstep_uart_tx_valid`（`top.sv:645`、`tb_verilator.cpp:574-590` の BUSYBOX トークン検出）が同じイベントを使い、二重出力や二重検出が起きない。
  - 現状は THR 書込みと同じ時点で `$write` している。本案では1サイクル後になり、THRE 割込みも1〜2サイクル遅れる。
  - オプション `+UART_TX_CYCLES=<n>`: 1バイトを n サイクルかけて出す（`tx_busy` を立てる）。THRE/TEMT を実時間に近い条件で試せる。既定は 0（現在の速度）。
- **RX**: `` `ifdef ENABLE_DEBUG_INPUT `` の中だけで、`rx_space` が 1 のサイクルに `util::get_input()` を呼ぶ。上位 20bit のマーカー（`0x01010`）が付いた値だけを push する（現 `uart_ns16550.sv:147-159` と同じ頻度・条件）。
  - DPI は空きがあるときだけ読むので、overrun は起きない（ホストの stdin が実質的なフロー制御）。
  - **DPI 入力が push まで1サイクル遅れる構成にする場合は、その予約分（取得済みでまだ push していない1バイト）を `rx_space` の判定に含める**（Codex 判断7）。つまり `rx_space = (rx_count_after_pop + inflight) < cap`。FCR[0]=0 なら cap=1。
  - 速度オプション `+UART_TX_CYCLES` は採用可。CPU 試験用の強制入力 plusarg は、必要が出てから追加する。backpressure と OE は regs/FIFO の単体試験で独立に検証する。
- `TRACE_UART`/`TRACE_RXUART`/`TRACE_TXUART` の `$display` は backend または `` `ifdef MINTS_SIM `` の監視ブロックへ移す。
- 注意 [確認]: debug MMIO の読出し（`top.sv:285-287`）も `get_input()` を呼ぶ。stdin の読み手が2つある状態は現状からのもので、本案では変えない。

### 8.2 FPGA backend（`uart16550_phy_top.sv`）
- TX: `uart_tx.tx_valid = regs.tx_valid`、`tx_data`、`regs.tx_ready = uart_tx.tx_ready`、`regs.tx_busy = uart_tx.tx_busy`、`divisor = tx_divisor`（6.2）。
- RX: `uart_rx.rx_valid/rx_data/rx_frame_err/rx_break` → `regs.rx_push/rx_data/rx_fe/rx_bi`。**PHY は止められない**。満杯なら regs が OE を立ててそのバイトを捨てる。`rx_space` は使わない。
- `tx_char_valid` 相当は出さない（`$write` は FPGA に存在しない）。デバッグ用には TX 転送イベントを LED や SignalTap へ出してよい。

## 9. OpenSBI v1.3.1 / Linux 6.12 に必要な機能（項目9）

| 利用者の手順 | 根拠 | 本案での必要機能 |
|---|---|---|
| OpenSBI init: IER=0、LCR=0x80、DLL/DLM（`bdiv=(in+8·baud)/(16·baud)` → 3.6864MHz/115200 = 2）、LCR=3、FCR=1、MCR=0、LSR と RBR を読む、SCR=0 | uart8250.c:93-133 [確認] | DLAB の切替、FCR0（変化でクリア）、LSR 読出しでの clear、空の RBR を読んでも無害なこと |
| OpenSBI putc: THRE をポーリングして1バイト書く | :72-78 [確認] | THRE = FIFO 空。2文字が重なって流れる（FIFO→PHY の転送で即 THRE=1） |
| OpenSBI getc: DR を見て RBR を読む | :81-86 [確認] | DR、pop |
| Linux probe: `ns16550a` → PORT_16550A、`UPF_FIXED_TYPE`、fifo 16、tx_loadsz 16 | 8250_of.c:109,322、8250_port.c:74-81 [確認] | 16段 TX FIFO。loopback による autoconfig は不要 |
| Linux startup: FIFO クリアと無効化、LSR/RX/IIR/MSR を読む、`LSR==0xff` チェック | :2237-2256 [確認] | LSR が 0xff にならないこと（PE=0 なので成り立つ） |
| THRE 再アサート probe | :2310-2345 [確認] | 4.2 の ETBEI 0→1 での set、IIR(THRE) 読出しでの clear |
| TXEN テスト | :2386-2399 [確認] | 4.2(b) |
| MCR: OUT2 を立てる | :2356-2366 [確認] | OUT2 は保存のみ。IRQ をゲートしない（現状どおり） |
| tx_chars: THRE 1回につき 16 バイト | :1790-1816 [確認] | THRE = 完全に空、16 段 |
| console fifo write: THRE 待ちの後に 16 バイト、最後に BOTH_EMPTY 待ち | :3306-3326、:3372-3395、:3401 [確認] | THRE/TEMT が正確なこと（3章） |
| handle_irq: IIR の NO_INT を見て、LSR → rx_chars（DR\|BI）→ THRE なら tx_chars | :1889-1930 [確認] | IIR bit0、DR/BI、FE/BI の付随 |
| set_termios: divisor（uartclk = DTS の 3.6864MHz）、LCR、FCR に R_TRIG_10 | [推測: 該当行は未精読] | FCR トリガは無視でよい（2.2）、DLAB |
| earlycon `uart8250,mmio,0x10000000`（baud 指定なし） | 8250_early.c:153-161 [確認] | divisor を設定し直さず、OpenSBI の設定を使う |

**PHY 第1段階だけでは足りないもの**: 上の表の FIFO・THRE/TEMT・IRQ・OE はすべて本案の regs 側で実装する。

## 10. 既存 UART テストの依存欠落と回帰方法（項目10）

- [確認・対応済み] 旧 `Makefile:229-239` の `bootrom-build` / `c-test-build` は `core/test/bootrom.S`、`core/test/link.ld`、`core/test/entry.S` を参照していた。しかし `.gitignore`（`core/test/*` を除外し、例外は個別の `.c` などだけ）のため、このクローンには**存在しない**。riscv-tests 用の `core/test/share` も同様。したがって `make test-uart*` は今のままでは実行できない。
- [確認] 既存テストの期待値と現 RTL のずれ:
  - `uart_regs.c` は IIR=0x01、IER=0x55 の読み返し、RBR=0x00 を期待している。
  - `uart_tx_irq.c` は IIR=0x02 を期待している。
  - 現 RTL は IIR=0xC1/0xC2、IER=0x05 を返す。**現状のテストは通らない可能性が高い**（未実行）。
- 推奨案:
  1. 欠けている3ファイルを、Git で追跡する新しい場所 `tb/sw/common/{bootrom.S, entry.S, link.ld}` に再作成する。中身は前回の推定どおり、bootrom は 0x80000000 へジャンプ、entry は sp を設定して `main` を呼ぶ、link.ld は 0x80000000 起点。
  2. Makefile に `C_TEST_COMMON_DIR ?= tb/sw/common` と `C_TEST_SRC_DIR ?= core/test` の変数を足して参照先を変える（Makefile の変更は別途承認が必要）。
  3. 期待値の修正は2点（IER=0x05、MCR は維持）に限り、理由と仕様の根拠を添えてレビューに出す。IIR の期待値（0x01/0x02）は本案に合うので変えない。
  4. まず**現 RTL のまま**で 1〜2 を行い、基準を記録した（実施済み。`fpga/de0-cv/UART_C_TEST_BASELINE.md`）。結果: `test-uart` と `test-uart-input` は PASS。`test-uart-regs`、`test-uart-tx-irq`、`test-uart-tx-seip`、`test-uart-rx-seip` は TIMEOUT で、原因はすべて IIR[7:6]=11（0xC1/0xC2/0xC4）が期待値（0x01/0x02/0x04）と違うこと（`+TRACE_UART` の記録で確認）。期待値の修正（IER 0x55→0x05）は、この基準記録とは別の変更として扱う（Codex 判断6）。
- `make test-custom-all`（`Makefile:403-407`）の UART 系5本（`test-uart-rx-seip` は `INPUT_TEXT=Z`）と `test-uart-input` を回帰の対象にする。

## 11. テスト設計とゲート（項目11）

### 11.1 regs 単体（`tb/unit/uart/tb_uart16550_regs.sv`、Verilator --binary --timing）
- Membus BFM（valid 保持、`ready` 待ち、`rvalid` 1回の確認、保持による二重受理が起きないこと）と、TX シンク（`tx_ready` をランダムに出す）、RX ソース（push を任意のタイミングで出す）を用意する。
- 検査項目:
  - リセット値: IIR=0x01、LSR=0x60、IER/LCR/MCR/SCR/DLL/DLM。
  - DLAB のレーン切替と、wmask が 0 の書込みを無視すること。
  - TX: 16 バイト連続書込みで欠落がない。17 バイト目は捨てられる（sim の `$error` 確認は別項目）。
  - THRE/TEMT の遷移（`tx_busy` の保持）。
  - THRE IRQ: 4.2 の各規則、Linux の probe 手順（a）（b）の再現、同時 pop/IER 書込みと同時 pop/THR 書込み。
  - RX: 16 段まで受理、17 段目で OE、LSR 読出しで OE クリア、同時 push/pop が満杯でも受理されること。
  - FE/BI のエントリ付随、head 表示と LSR 読出しでの消去、FIFOE、RLS > RDA > THRE の優先順位。
  - FCR: クリア、FCR0 の変化でのクリア、FCR0=0 のときクリアビットが無視されること、push との同時、TX clear エッジで handoff が出ないこと。
  - **FCR[0]=0 の有効容量1**: TX は2バイト目で溢れる（診断あり）、RX は2バイト目で OE。IIR[7:6]=00、LSR7=0。
  - LSR7 と head ack: head だけがエラー → LSR 読出しで FE/BI/FIFOE が 0。後続にもエラー → FIFOE が残る。ack と head の変化が同時 → 新しい head は未 ack。
  - THRE 規則1〜5（同時事象を含む）。
  - DLAB 中に TX が新しいフレームを始めないこと。RX は DLAB 中も受信し、divisor 更新後の速度で受けること。
  - TX の divisor ゲート（採用時）。
  - 期待値はテスト内で独立に組んだモデル（キューとフラグ）から作り、DUT の内部信号は使わない。
- **regs + PHY の結合 TB（必須、Codex 判断8）**: `uart16550_phy_top` と第1段階の TB のホスト送受信タスク（独立モデル）を使う。
  - MMIO から 115200 で 256 値を送信し、ホスト側でデコードして一致を確認する。
  - ホストから 256 値を送り、RDA IRQ を受けて RBR で読み出す。
  - 連続受信で CPU 側（TB）が読まないときの OE 発生。
  - BREAK が1エントリ（00、FE、BI）になること。
  - TEMT が送信完了（stop の終わり）で立つこと。

### 11.2 SoC sim（CPU から MMIO）
- 10 章の回帰（UART C テスト5本＋入力2本）を、RTL の置換前と置換後で比べる。
- 新しい C テストを追加する: 16 バイト連続書込み後の THRE 待ち、THRE IRQ の probe 手順（Linux と同じ順序）、RX の OE（DPI では起きないので、backend の試験用 plusarg で強制的に push する案。未決定）。

### 11.3 OS レベルのゲート
1. `bash tools/run-linux.sh`（autotest、BUSYBOX-TEST-PASS）。置換前後の両方で PASS すること。lockstep 版（`run-opensbi-lockstep`）は Whisper 側の MMIO の扱いが未確認なので、実施可否を別途確認する。
2. **対話 RX ゲート**: `cmdloop-ttyS0` イメージ（Docs に名前があるが未ビルド）を作る。`run-opensbi-input` に stdin から `echo UART-RX-OK\n` などを流し、エコーと出力の一致を自動で判定するスクリプトを用意する。入力した文字の欠落・重複がないこと（7章のリスク確認を兼ねる）。
3. sim で PHY を通す**追加ゲート**（最初の必須条件ではない。Codex 判断8）: C++ ハーネスでビットレベルの rxd を駆動して txd をデコードし、sim backend の代わりに PHY を通して Linux を起動する。時間がかかるので、OpenSBI のバナーまででもよい。実機の前の最終確認として提案するが、必須かどうかは未決定。
4. **実機ゲート**（Quartus とボードが使えるようになってから）: echo、OpenSBI のバナー、Linux の対話。sim の PASS とは別に記録する。

## 12. 判断済み事項（Codex レビュー 2026-11-09）

| # | 項目 | 判断 |
|---|---|---|
| 1 | FCR[0]=0 書込み時の clear/trigger | 無視する。enable の切替によるクリアは有効。RX clear と push が同時ならクリア後に新しいバイトを残す。TX clear の受理エッジでは新しい handoff を出さず、送信中のフレームは止めない（2.2） |
| 2 | ETBEI=0 時の pending | 0 にする。書込み後の IER を優先して判定する。ETBEI=1 なら新しい事象が IIR 読出しの clear に勝つ（4.2） |
| 3 | DLAB 中の TX | 新しいフレームを止める（案 A）。8N1 向けの実装判断として明記（6.2） |
| 4 | MCR loopback | 範囲外。保存のみ。未対応と明記し、全機能互換は主張しない（6.3） |
| 5 | FE/BI | エントリに付随させ、LSR 読出しで現在の head を ack。新しい head は ack を継承しない。OE は sticky で新しい overrun が勝つ。LSR7 の定義は5章で明記 |
| 6 | テスト基盤 | `tb/sw/common/` に復元し Makefile を変数化（実施済み）。期待値修正は基準記録の後の別変更 |
| 7 | sim backend | 速度オプションは採用可。backpressure と OE は単体試験で独立に検証。強制入力 plusarg は必要時に。DPI の1サイクル遅延分は rx_space の予約に含める |
| 8 | PHY 結合試験 | regs+PHY のビットレベル結合試験は必須。PHY 経由のフル Linux 起動は追加ゲート。通常の Linux autotest と対話 RX は SoC 変更後に必要 |
| – | FIFO 無効時の容量 | 物理16段、FCR[0]=0 の有効容量は1（2.1） |
| – | RX trigger/timeout | トリガ1固定・タイムアウト未実装は暫定の範囲として許容。読み返せても動作に反映しないことを明記。overflow は診断可能にする |

## 13. 実装の順序案（GO 後）
1. 10章の依存復元と、現 RTL での回帰基準の記録（RTL は変更しない）。
2. `uart16550_regs` と単体 TB。
3. sim backend への置換（`uart_ns16550.sv` をラッパー化、`core.f` に追加）。C テストの回帰と Linux autotest。
4. `uart16550_phy_top` と結合 TB。
5. 対話 RX ゲート。
6. （ボードが使えるようになったら）FPGA の top へ組み込む。


## 14. 実装ノート（regs 単体。2026-11-09）

### 14.1 追加ファイル
| ファイル | 内容 |
|---|---|
| `rtl/peripheral/uart16550_regs.sv` | 本設計の regs/FIFO。FIFO はモジュール内に直接書いた（`uart_fifo.sv` は作っていない）。`` `ifdef MINTS_SIM `` の中だけに `$error` がある |
| `tb/unit/uart/tb_uart16550_regs.sv` | 単体 TB（Membus BFM、TX シンクと PHY busy モデル、RX ソース） |
| `tb/unit/uart/uart16550_regs_tb.f` | filelist（`src/eei.sv`、`src/membus_if.sv`、regs、TB） |

既存の `src/uart_ns16550.sv`、`core.f`、Makefile、C テスト、CPU には接続していない。

### 14.2 実装上の決定
- リセット値: `LCR=0x03`（現 `uart_ns16550.sv` と同じ。16550 の仕様では 0x00）、他は 0、`FCR[0]=0`（容量1、IIR=0x01）。
- 書込み応答の rdata は 0。読出しは更新前の状態をレーンに置き、他のレーンは 0。
- IIR の読出しは DLAB に関係なく有効（現 RTL は DLAB=1 で IIR の副作用を止めていた）。
- THRE の clear は「THR への書込み（lane 有効）」で起こる。満杯で破棄された書込みでも clear するが、満杯なら FIFO は空でないので pending はもともと 0。
- FIFO 本体（`tx_mem`/`rx_mem`）はリセットなしの別の always_ff に置いた（RAM 推論のため）。中身は count で修飾されるので、空の FIFO の RBR 読出しは 0x00 を返す。
- 合成可能部に DPI・`$write`・`$test$plusargs` はない。

### 14.3 TB の検査項目
| テスト | 内容 |
|---|---|
| `t_reset_values` | リセット値、DLAB 経由の DLL/DLM、出力の初期値 |
| `t_lanes_dlab` | wmask の誤レーン書込みの無視、`addr[7:3]` のエイリアス、IER/MCR のビット幅、LSR/MSR への書込みの無視、DLAB の切替、divisor |
| `t_held_valid` | valid を3サイクル保持しても受理・rvalid は1回で、THR push と RBR pop も1回 |
| `t_tx_fifo16` | 16 段の境界、満杯+同時 pop で受理、満杯で破棄 → sticky 診断、THRE/TEMT と PHY busy |
| `t_cap1` | FCR0=0: IIR=0x01、TX は容量1（満杯+pop で受理、2つ目は破棄）、RX は2つ目で OE、満杯+pop+push |
| `t_fcr_clear` | TX clear と tx_ready が同じサイクル → handoff なし、clear は送信中フレームを止めない（TEMT）、RX clear+push → 新しいバイトが残る、FCR0 の切替（1→0、0→1）で両 FIFO クリア、FCR0=0 の clear ビットを無視 |
| `t_dlab_tx` | DLAB 中は tx_valid が Low（常時監視）、解除後に再開 |
| `t_rx_fifo16` | 16 段の境界、OE の sticky と LSR 読出しでのクリア、満杯+pop+push、LSR 読出しと新しい overrun の同時（読み値は旧状態、OE は set が勝つ） |
| `t_head_error` | FE/BI のエントリ付随、head の表示と ack、LSR7（未 ack 数）、LSR 読出しと新しい head の同時（新しい head は未 ack）、FCR0=0 で FIFOE=0 |
| `t_irq` | Linux の THRE 再アサート probe、TXEN テストの手順、IER 1→1 で再 set しない、ETBEI=0 で pending=0、THR+最後の pop の同時、ETBEI の立上り+最後の pop の同時、**IIR 読出し+最後の pop の同時**（読み値は旧状態 0xC1、新しい空遷移が set）、**IER=0 書込み+最後の pop の同時**（新しい IER が勝ち pending=0。ETBEI=0 では IIR から見えないので白箱で確認）、優先度 RLS>RDA>THRE、OE による RLS |
| `t_mcr_no_loopback` | MCR[4]=1 を保存して読み返せる。TX は実際に handoff され、RX へは折り返さない（LSR.DR=0）、MSR=0 |
| `t_diag_reset` | 診断は LSR 読出しで消えず、リセットで消える |
| 常時チェック | FIFO 数の範囲、`rx_err_cnt <= rx_count`、FCR0=0 で数 ≤ 1、`irq == (IIR != 0x01)`、DLAB 中の tx_valid、Membus の受理と rvalid がそれぞれ1回、レーン外の rdata が 0 |

期待値はテストごとに仕様から手で書いた。白箱で参照しているのは、常時チェック（FIFO 数、IIR、`thre_pending`/`ier`）と、`t_irq` (g)(h) の `thre_pending`/`tx_count` だけ。

- **到達できない競合**（白箱の常時チェックで裏付け）: THRE pending は空への遷移でしか set されず、THR 書込みで clear されるので、`thre_pending ⇒ tx_count == 0` が不変条件になる。したがって「IIR 読出しが THRE を返す」ことと「TX の pop」は同じサイクルに起こらない。テストできる競合は (g)（THRE を返さない IIR 読出しと、最後の pop による set）で、「新しい set が read clear に勝つ」規則の実装は RTL の `thre_pending_next` 式で担保している。
- **TB のタイミング規約**（Codex 指摘 2026-11-09 で修正）: posedge のモニタ（TX 受信キュー、PHY busy、受理と rvalid の計数）と同じ Active 領域で刺激を変えたり検査したりしないため、刺激の変更・キューの検査と削除・カウンタの検査はすべて negedge で行う。`wait_cycles(n)` は n 回の posedge を待ってから次の negedge で戻る。`bus_op` も最後の検査を次の negedge で行い、negedge で戻る。posedge で読むのは DUT のレジスタ値（NBA 前の値）だけにした。

### 14.4 予定コマンド（未実行。Codex の差分レビュー後に実行する）
```sh
# 機能試験（MINTS_SIM なし）。合格: UART16550_REGS_TB_PASS かつ終了コード0
verilator --binary --timing --assert --timescale 1ns/1ps \
  -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs \
  --Mdir build/test/uart-regs/obj -o tb_uart16550_regs
build/test/uart-regs/obj/tb_uart16550_regs

# 異常系プロファイル（MINTS_SIM の $error）。合格: 終了コードが非0、ログに
# "uart16550_regs: THR write dropped" があり、UART16550_REGS_SIM_ERROR_NOT_RAISED がない
verilator --binary --timing --assert --timescale 1ns/1ps +define+MINTS_SIM +define+TB_SIM_ERROR_PROFILE \
  -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs \
  --Mdir build/test/uart-regs/obj_simerr -o tb_uart16550_regs_simerr
build/test/uart-regs/obj_simerr/tb_uart16550_regs_simerr

# lint（regs はインタフェースのポートを持つので、TB を top にして -Wall。MINTS_SIM の有無の両方）
verilator --lint-only -Wall --timing -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs
verilator --lint-only -Wall --timing +define+MINTS_SIM -f tb/unit/uart/uart16550_regs_tb.f --top-module tb_uart16550_regs
```
- 実行用の runner スクリプトはまだ作っていない（TB 修正後も lint・コンパイル・シミュレーションは未実行）。GO 後に `tools/test-de0cv-uart.sh` に追加するか、専用の runner を作る。

### 14.5 懸念点（未検証）
- `tx_valid` が FCR 書込みのデコードに組合せで依存する（membus → tx_valid → PHY の tx_ready → pop）。ループはない（PHY の tx_ready は tx_valid に依存しない）が、組合せ経路は長くなる。
- `rx_space` も同じサイクルの RBR pop に組合せで依存する。sim backend はそのサイクルに DPI を呼ぶ。
- Verilator 5.046 で次が通るかは未確認: interface の modport 越しに `always_ff` から `membus.rdata` へ非ブロッキング代入、関数内での可変範囲の部分選択、TB の `input logic fe = 1'b0` の既定引数、キュー引数（`input logic [7:0] exp[$]`）、`'{...}` によるキューへの代入、TB からの白箱参照（`dut.tx_count`）。
- `-Wall` の lint では、TB 側に WIDTH/UNUSED 系の警告が出る可能性がある。その場合は意味を変えない範囲で直し、抑止はしない。
- 現 RTL と違う挙動: IIR[7:6] は FCR0 に従う（現 RTL は常に 11）。LCR のリセット値 0x03 は維持。RBR を空で読むと 0x00（現 RTL は FIFO 内の古い値）。sim wrapper へ置き換えると既存 C テストの IIR 期待値と一致する見込みだが、未検証で、次のゲートで確かめる。
- `uart_tx_irq` のような既存 C テストへの影響は、まだ接続していないので評価していない。


### 14.6 regs 単体の検証結果（2026-11-09、Codex の GO 後に実施）
- 実行: `bash tools/test-uart16550-regs.sh`（Docker `mints-linux-verilator:5.046`）。runner の終了コードは0。ログは `build/test/uart-regs/`。
- **lint**（`-Wall`、regs を top にし、`MINTS_SIM` なしとありの両方）:
  - `uart16550_regs.sv` の警告は0。初回の lint で出た regs 由来の4件は、意味を変えずに直した。
    1. IMPORTSTAR: `$unit` での import を、モジュールヘッダ内の import に移した。
    2. SYNCASYNCNET: `MINTS_SIM` の検査ブロックを非同期リセット形式に揃えた。
    3. UNUSEDSIGNAL `ier_next`[3:2,0]: 1bit の `etbei_next` に置き換えた。
    4. UNUSEDSIGNAL `fcr_trig`: 仕様上は保存するだけなので、その宣言にだけ `lint_off` を付けた。
  - 既存の共有ファイル由来の警告66件は、範囲外なので無効化せず、件数を記録した。内訳は `src/eei.sv` の UNUSEDPARAM 59件と、`src/membus_if.sv` の DECLFILENAME 1・IMPORTSTAR 1・VARHIDDEN 1・UNUSEDSIGNAL 4（interface を top で使ったことによる ready/rvalid/rdata と、仕様で無視する `addr[63:3]`）。このため Verilator 自体の終了コードは1になる。
- **機能 TB**（MINTS_SIM なし）: ビルド警告0。12 テストグループすべて PASS で `UART16550_REGS_TB_PASS`、終了コード0（シミュレーション時間 15us）。
- **異常系プロファイル**（`+define+MINTS_SIM +define+TB_SIM_ERROR_PROFILE`）: ビルド警告0、終了コード1。ログには `%Error: ... uart16550_regs: THR write dropped, TX FIFO full (count=1 cap=1)` に続いて `Verilog $stop` があり、`UART16550_REGS_SIM_ERROR_NOT_RAISED` は出ていない → 期待どおり。
- 未実施: regs+PHY の結合 TB、sim wrapper と `core.f` への接続、既存 C テストと Linux の回帰、合成。
