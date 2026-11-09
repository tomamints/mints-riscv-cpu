# DE0-CV 移植 実装前レビュー（Claude, task_8db404967b7a）

- 対象: branch `fpga/de0-cv-bringup` / 基準 `3374f8c`（未追跡 `Docs/DE0_CV_IMPLEMENTATION_STATUS.md` を含む作業ツリーを読取りのみ）
- 範囲: 設計レビューのみ。RTL/Docs/スクリプト編集・テスト・合成・Git操作・ボード操作は一切していない。
- 表記: **[確認]**＝このクローンのコード/ファイルで確認、**[推測]**＝コードや一般知識からの推論で未検証、**[未検証]**＝実機・ツール・一次資料での確認が必要。
- 実装やFPGA動作の成功を示すものではない。

## 判定: 条件付きGO

Codex案の方向（Sv39/M/S/U維持、reset vector 0x1000維持、UART仕様を先に固める、LED→UART→SDRAM単体→CPU、CRC読み戻しを成功条件にする、PMPを即削除しない）は妥当。
ただし以下の **C1〜C4 を実装前に仕様へ追加** すること:

- C1: PMP=0 は現 `pmp_checker` のままでは S/U の全アクセスを拒否する（指摘1）。
- C2: RAM 容量の単位を1か所で定義し、デコード上限・キャッシュ可能範囲・DTS・ローダ定数を同じ値から作る（指摘2,3,4）。
- C3: SDRAM ブリッジ契約（応答タイミング・書込み応答・1 outstanding・エラー時ハングなし）を文書化し、**Verilator の可変遅延メモリで既存 Linux autotest を通すゲート** を SDRAM 実装前に追加（指摘5,6）。
- C4: UART は「16550 レジスタ」と「バイトストリーム（sim DPI アダプタ / 実 PHY）」に分割し、THRE=TX FIFO 空、TX FIFO 16段以上、OE、baud 基準クロックと DTS の一致を仕様化（指摘7〜9）。

---

## 指摘（重要度順）

### 1. [Critical][確認] PMP=0 にすると Linux が即死する
- 根拠: `src/pmp_checker.sv:108-160`。M 以外では `allow=0` から始まり、一致エントリがなければ拒否。
- 失敗: エントリ数を0にした（またはループ上限だけ縮めた）場合、S/U の全 fetch/load/store/PTW が access fault になる。RISC-V Privileged 仕様では、PMP が1つも実装されていなければ S/U のアクセスは成功する。
- 推奨: PMP 8 を維持し、Codex案のとおり即削除しない。縮小するときは次のいずれかにする。
  - (a) `PMP_ENTRIES` パラメータ（例: 8→4→2）。未実装の `pmpaddrN/cfg` は WARL 0 固定（`src/csrunit.sv:418-` 付近）。
  - (b) PMP 粒度 G を広げる（例: 4KiB）、物理アドレス幅を制限する（`PMPADDR_WMASK` `src/eei.sv:43` の54bit→実PA幅）。どちらも仕様の範囲内で、比較器の幅が減る。
  - 0 にするなら「実装数0 → allow=1」の分岐、CSR の read-only-zero、OpenSBI 1.3 が PMP 数0を検出して `pmp_configure` を飛ばすことを、すべて Verilator Linux で確認してからにする（OpenSBI 側の挙動は[推測]）。
- 補足[確認]: checker のインスタンスは4つ（`src/inst_fetcher.sv:202,678`、`src/memunit.sv:399`、`rtl/mmu/address_translation.sv:342`）。復旧計画の「5か所」とは数が合わない。

### 2. [High][確認] RAM 単位の混同で、キャッシュ可能範囲が実は 16MiB
- 根拠: `src/eei.sv:52` の `RAM_ADDR_WIDTH=24` は 64bit ワード index の幅（`src/top.sv:127-131` `addr[3 +: 24]`、`memory.sv:17` → 2^24×8B = 128MiB）。一方 `rtl/cache/icache.sv:33` と `rtl/cache/dcache.sv:38` は `END = BEGIN + (1<<24)` = **0x8100_0000（16MiB）**。
- 影響: 現在の Linux PASS は「16MiB より上はアンキャッシュ」で動いた結果。Image 3.8MB（`build/external/linux-out`）は下位 16MiB に入るが、ページアロケータが上位に置いたものはアンキャッシュで動いている。
- 64MiB 移植で `RAM_ADDR_WIDTH=23` に直すと、キャッシュ範囲は 8MiB に縮む。バイト数と思って 26 にすると、配列は 512MiB になる。
- 推奨: `RAM_SIZE_BYTES`（sim 128MiB / FPGA 64MiB を macro かパラメータで切替）を正とし、`RAM_WORD_ADDR_WIDTH=$clog2(RAM_SIZE_BYTES/8)` と `MMAP_RAM_END` を導出する。キャッシュ範囲を 16MiB→全容量へ広げるのは「キャッシュされる範囲が増える＝挙動変更」なので、**単独コミットにして Linux autotest を再実行**する。

### 3. [High][確認] RAM デコードに上限がなく、上位アドレスが折り返す
- 根拠: `src/mmio_controller.sv:76` `addr >= MMAP_RAM_BEGIN` → RAM。`top.sv:130` は上位ビットを捨てる。
- 失敗: 64MiB 実機で上限を作らないと、0x8400_0000 以降への書込みが 0x8000_0000（OpenSBI 本体）を破壊する。さらに今の `bootrom_linux.S:5` の DTB 0x87f0_0000 は 0x83f0_0000 に**偶然折り返して動いてしまい**、設定ミスが隠れる。
- 推奨: RAM は `[BEGIN, BEGIN+RAM_SIZE_BYTES)` だけにし、範囲外は指摘4のエラー応答にする。SDRAM ブリッジ側でも上位ビット≠0 を assert で検出する。

### 4. [High][確認] 未定義アドレスで SoC が永久停止する（エラー応答がない）
- 根拠: `mmio_controller.sv:138`（UNKNOWN は捨てる）、`:164`（UNKNOWN の ready=0）。`req_saved.valid` が落ちないので、I/D 両方のバスが止まる。`Membus` に error 信号はなく、access fault は PMP 由来だけ（`memunit.sv:772,807`）。
- 失敗: Linux/OpenSBI/ローダのバグや DTS のずれで未マップ領域に触れると、UART も含めて完全に無反応になり、FPGA 上では原因を切り分けられない。
- 推奨: 第1段階は、UNKNOWN と RAM 範囲外に「1サイクル後に rvalid、rdata=0」で応答し、sticky なエラーアドレスレジスタと LED 表示を付ける（ハングをなくす）。第2段階で `rsp_error` を追加し、load/store/fetch access fault へつなぐ（コア変更なので別レビュー）。

### 5. [High][確認] SDRAM へ置き換えるときのバス契約（現実装から導いた必要条件）
現 RTL が暗黙に要求している条件。ブリッジはすべて満たすこと。
1. **1 outstanding（システム全体）**: `mmio_controller` は1件だけ保持（`:215` `ready=!req_saved.valid`）。`ram_arbiter_cpu_prio` も IDLE→WAIT で1件。ID・並べ替えは不要だが、ブリッジが2件目を受理してはいけない。
2. **rvalid は受理の1サイクル以上後**: `mmio_controller.sv:255-262` は受理の次サイクルに `req_issued=1` になってから rvalid を見る。`ram_arbiter.sv:32` も WAIT 中だけ転送する。**受理と同じサイクルの組合せ rvalid は取りこぼし、ハングする。**
3. **書込みにも rvalid を1回返す**: `memory.sv:86-89`、arbiter/mmio は書込みでも rvalid を待つ。rready はないので、応答は1サイクルのパルスで必ず受け取られる前提。
4. **ready の Low 期間は任意長**: リフレッシュや ACT 中は Low でよい（mmio・arbiter とも valid/addr を保持する）。valid が立つ前に ready を出してよい（現 memory は組合せ ready）。
5. **アドレス単位**: arbiter 出力 `arb_ram_membus.addr` は RAM 先頭からのバイトオフセット（`mmio_controller.sv:94`、`dma.sv:191-192`）。`ram_membus.addr` は 64bit ワード index。下位3bitは無視され、wmask[7:0] がバイトイネーブル（ミスアラインは memunit が先にトラップする[推測]）。x16 SDRAM では 64bit = 4 beat、DQM = wmask の2bitずつの反転。読出しは常に 64bit 全体。
6. **書込み応答の rdata**: `memory.sv:89` は旧データを返す。amounit の commit は `AMOStoreValid && master.rvalid`（`amounit.sv:66`）で値はロード時のもの、と[推測]。ブリッジは 0 を返し、「書込み応答 rdata を使う消費者がない」ことを grep と assert で確認する。
7. **AMO はバス上でロード＋ストアの2トランザクション**（`amounit.sv`）。単一 CPU と per-transaction の調停だから原子的に見えているだけ。DMA（または UART-DMA ローダ）が間に入ると壊れる。Linux 実行中は DMA を止める（DT に DMA ノードがないので[推測]で実害なし）か、AMO 中は arbiter をロックする。
8. **書込みの早期応答（posted write）をするなら**、後続の読出しへのフォワードと順序保証が必要。最初は「SDRAM WRITE コマンドを発行してから rvalid」の in-order 制御にする。
9. **リセット順序**: PLL locked → SDRAM 初期化（電源投入待ち、PRECHARGE ALL、AUTO REFRESH×n、MRS）完了まで CPU の `rst` を保持する。`rst` は負論理の非同期リセット（全モジュール `negedge rst`）なので、解除側を同期化するリセットシンクロナイザが必要。
10. **クロック**: 最初は CPU とコントローラを同一クロック（DRAM_CLK だけ PLL で位相シフト）にして CDC をなくす方を推奨。復旧計画 G6 の「CDC含む」は必須ではなく、選択肢として扱う。SDRAM の型番とタイミングは DE0-CV User Manual・データシートと照合するまで[未検証]。

### 6. [High][推測] 可変遅延を Verilator で先に通さないと、実機での切り分けが困難
- `memory.sv` は固定の1〜2サイクル応答なので、I/D キャッシュ・store buffer・PTW・amounit・fast_load 経路は長い待ちや不規則な待ちで試されていない。
- 推奨ゲート（新規 G1.5）: sim 用 `memory.sv` に「ready のランダム停止」「rvalid 遅延 1..N（N=30程度、ときどき 200+ でリフレッシュを模擬）」を入れ、seed 固定で `riscv-tests` と Linux BusyBox autotest を PASS させる。SDRAM 実装の前に、M1 だけで実施できる。

### 7. [High][確認] UART TX: THRE/TEMT 固定・即時 $write は実 PHY ではそのまま使えない
- 根拠: `uart_ns16550.sv:58` LSR=`0x60|DR` 固定。`:179-184` THR 書込みは即 `$write` し、翌サイクルに `tx_empty_event`（`:133-145`）で THRE IRQ を立てる。TX FIFO はない。
- 実 PHY をつないだときの失敗:
  - 1バイト 86.8µs（115200）かかる間も THRE=1 なので、OpenSBI の `uart8250_putc`（THRE ポーリング）は連続で書き、2バイト目以降が欠落する。
  - Linux の 8250 ドライバは `ns16550a`（`riscv_cpu.dts:52`）を 16550A（fifosize=16）として扱い、THRE 割込み1回につき**最大16バイトを LSR を見ずに**書く[推測: tx_loadsz=16]。TX FIFO が16段未満、または THRE を「not full」と定義すると欠落する。
  - THRE IRQ が書込み直後に立つので、IRQ が止まらない、または送信中にドライバが次を書き、欠落する。
- 推奨仕様:
  - TX FIFO 16段以上。THRE = **TX FIFO 空**、TEMT = FIFO 空かつシフタ idle。
  - THRE 割込みの条件: (i) IER.ETBEI が 0→1 で FIFO 空のとき（Linux の startup で THRE をテストする。`:192-197` の現行挙動を維持）、(ii) FIFO が空になった遷移。クリア条件は THR 書込み、または THRE が要因のときの IIR 読出し（`:112,216` の現行挙動を維持）。
  - FCR bit2 で TX FIFO をクリア（現在は無視）。
  - FIFO が満杯のときの THR 書込みは破棄し、sim では assert する。

### 8. [High][確認] UART RX: 満杯時の扱い・OE・同時 push/pop
- 根拠: `:148` DPI は `rx_count_after_pop < 16` のときだけ取り込む（sim では入力側が待つ）。実 PHY は待てない。`:285-288` `rx_clear` と push が同じサイクルだと push が消える。LSR に OE/FE/BI がない。
- 推奨:
  - PHY→FIFO は valid だけ（ready なし）で、満杯なら破棄して LSR.OE を sticky にする（LSR 読出しでクリア）。
  - 同時 push/pop は現行の `2'b11` の扱いを維持し、満杯での同時 push/pop は「pop してから push」で成立させる。
  - FE（stop=0）と BI に対応する。
  - RX は 2FF 同期、16x オーバサンプリングで中央サンプル、スタートビットの半ビット再確認（グリッチ除去）。
  - DR が立ったらすぐ IIR=0x04 を返す現行仕様（トリガレベル1相当）なら、文字タイムアウト（0x0C）は不要。FCR のトリガレベルを無視することは明記する。
- ローダ: 115200 で連続受信、FIFO 16 段では CPU のポーリング遅延で溢れうる。チャンク ACK 方式（例: 256B〜4KiB ごとに ACK/NACK）と OE 検出時の NACK・再送を必須にする。

### 9. [High][確認] baud 基準クロックと mtime が DTS と食い違う
- UART: `riscv_cpu.dts:56` `clock-frequency=0x384000`（3.6864MHz）。OpenSBI と Linux はここから divisor（115200 なら 2）を計算し、DLL/DLM へ書く。現 RTL は DLL/DLM を保存するだけ（`:177,189`）。
  - 実 PHY を CPU clk / (16×divisor) にすると、基準が合わず baud が外れる。
  - 推奨 (a): CPU clk から位相アキュムレータで 3.6864MHz 相当の enable を作り、16550 本来の divisor 計算を使う。DTS・OpenSBI・Linux・sim がそのまま一致する。
  - 推奨 (b): DTS を実クロックへ変更する。ただし 25MHz なら divisor 14 で誤差約 3.1%、20MHz なら 11 で約 1.4%、50MHz なら 27 で約 0.5%。誤差の評価が必要。
  - divisor=0（リセット直後、`:76-77`）のときの PHY の挙動も定義する。
- タイマ: `aclint_memory.sv:49` mtime は clk ごとに +1、DTS `timebase-frequency=50000000`（`:21`）。FPGA の CPU を 20MHz などにするなら、DTS を合わせるか、固定周波数の tick を作る。合っていないと Linux の時刻・遅延・ソフトロックアップ判定がずれる。
- DTS `cpu clock-frequency`（`:28`）も合わせる（表示用、[推測]で影響は小さい）。

### 10. [Medium][確認] DTB/ROM/メモリマップの定数が3か所以上に分散している
- `platform/bootrom_linux.S:5` の `a1=0x87f00000` は直書き。`Makefile:110-113`（`LINUX_DTB_ADDR/OFFSET`、`LINUX_RAM_SIZE=0x8000000`）。`riscv_cpu.dts:42`（128MiB）。
- OpenSBI 1.3 generic は `FW_JUMP_FDT_ADDR=0x82200000`（`build/external/opensbi/platform/generic/objects.mk:35`）。FDT を a1 からここへ再配置して Linux へ渡すと[推測、fw_base の挙動。OpenSBI の起動ログで確認すること]。つまり実際の DTB アドレスは2つある。0x8220_0000 は 64MiB の範囲内なので、そのまま使える。
- 推奨:
  - 1つの設定（例: `platform/de0cv_memmap.mk` か生成ヘッダ）から DTS の memory、ローダ/ROM の DTB 引数、`make_linux_ram_hex.py` の size、eei の `RAM_SIZE_BYTES` を生成する。
  - DTB のロード先は 64MiB 内（例 0x83f0_0000。ローダのスタック・作業域は別に予約）。
  - 「Image ヘッダの `image_size`（BSS を含む）+ 0x8020_0000 < 0x8220_0000」をビルド時にチェックする（今は 3.8MB で余裕）。
- reset vector: 0x1000 維持に賛成（`eei.sv:59,108`）。0x0 案を採る理由は現時点でない。ただし ROM 窓は `MMAP_ROM_END=0x13ff`（1KiB）なのに配列は `ROM_ADDR_WIDTH=9` で 4KiB（`eei.sv:57-60`）と食い違っており、CRC 付き UART ローダは 1KiB に収まらない可能性が高い[推測]。ROM 窓を 4〜8KiB に広げる（icache の cacheable ROM 判定 `icache.sv:95` は `MMAP_ROM_END` から導出されるので追従する）。

### 11. [Medium][確認] キャッシュ・BTB の ALM の主因は全幅タグ。同期 RAM 化の前に、意味を変えずに削れる
- `icache.sv:32` の `TAG_WIDTH = 64-5-7 = 52bit`（dcache も同様[推測]）、`branch_predictor.sv:43` の `BTB_TAG_WIDTH = 58bit`×32。
- キャッシュ可能範囲を「RAM 64MiB + ROM」に限定しているので、タグは `RAM オフセットの上位ビット + 領域 1bit` で足りる（cacheable 判定がヒット条件に含まれていることが前提。`icache.sv:96` で確認済み）。BTB の部分タグは予測精度だけの問題だが、**ターゲット不一致が必ず brunit で検出・回復されること** を先に確認すること[未検証]。
- 同期 RAM 化の注意[確認]: icache は `cache_hit` を組合せで出して `req_ready` に使っている（`:96,113-125`）。dcache には同サイクルの `fast_load_valid/data`（`core_data_if.sv:16-23`）がある。M10K 化は「1サイクル増やす」だけでは済まず、**fast_load 経路とパイプラインのタイミング変更**になる。

### 12. [Medium][確認] 合成できない構文の分離
- 該当箇所:
  - DPI: `util.sv` 全体と、それを使う `memory.sv`（`get_env`）、`top.sv:286`、`uart:150`。
  - `$readmemh`（環境変数パス）。
  - `$write/$fflush/$finish/$error`: `top.sv:262-289` の debug MMIO、`uart:179`。
  - `$test$plusargs`（uart、aclint、caches）。
  - `final`（`top.sv:630`、各 perf）と 64bit perf カウンタ群（`top.sv:292-326`、icache perf）。
  - lockstep 出力。
- 推奨:
  - `top.sv` を「`soc_top`（コア＋キャッシュ＋MMIO＋外部 RAM Membus ポート＋UART バイトポート）」と「`sim_top`（memory.sv＋DPI UART アダプタ＋debug MMIO）」と「`de0_cv_top`（PLL/reset＋SDRAM ブリッジ＋UART PHY＋M10K ROM）」に分ける。FPGA と sim が同じ fabric を通るようにする。
  - sim 専用の構文は `ifdef MINTS_SIM`（Verilator 側で定義）で囲む。perf は `ENABLE_PERF` パラメータで落とす。
  - Quartus が `SYNTHESIS` を自動定義するか、`final` や `$test$plusargs` を無視するかエラーにするかは[未検証]。qsf の `VERILOG_MACRO` で明示的に定義する方が確実。
  - `core.f` とは別に `fpga.f` を作る。
  - `MMAP_DBG_ADDR` 入力（`mmio_controller.sv:70` で最優先にデコード）を FPGA で 0 に固定すると、0x0〜0x7 が debug 扱いになる。debug デバイスは外すか、無害な固定アドレスにする。
  - `aclint_memory.sv:49` の always_ff 内のブロッキング `+=` は合成上は動く[推測]が、`<=` へ整理する。

### 13. [Medium][確認] DMA はキャッシュを経由しない
- `dma.sv:85-92` は arbiter へ直接書くので、write-through D-cache の有効ラインと I-cache が古いまま残る。dst の範囲チェックもない（`:192`）。
- 別案「UART-DMA ローダ」を採るなら、CPU 解放前のキャッシュ無効化（リセット中にロードするなら不要）、範囲チェック、AMO との排他が必要。第一候補のソフトウェアローダなら、**ロード後の `fence.i`（store buffer の排出＋I-cache 無効化）を通ってから OpenSBI へ飛ぶこと**をテストに含める。

### 14. [Low][確認] 対話シェル用イメージがまだない
- `build/external/linux-out` には autotest の Image しかない。Docs に名前がある `cmdloop-ttyS0` 版は未ビルド。
- 対話には RX 割込み（UART→PLIC src10→SEIP→8250）が必要だが、autotest は主に TX しか使わない[推測]。
- 実機の前に、Verilator で「新 UART レジスタ＋（DPI アダプタ／ビットレベル PHY＋ホストモデル）」を使い、対話イメージに複数行の入力と echo を通すゲートを置く。

### 15. [Low][未検証] 物理配線
- 復旧計画 §4.6 の JP1 8/10/12 番、FTDI の色、3.3V LVTTL は過去の報告に基づく値で、正式な DE0-CV User Manual の GPIO ピン表と照合していない。qsf の pin 割当は照合後に確定する。5V ピン（JP1 11番とされるもの）を避けることも、資料で確認する。

---

## ゲート見直し（抜けと追加）

| 追加/変更 | 内容 | 理由 |
|---|---|---|
| G1.5 新規 | Verilator 可変遅延メモリで riscv-tests と Linux autotest | 指摘5,6。SDRAM と CPU 側の不具合を分離する |
| G1.6 新規 | UART 分割後の regs＋PHY ビットレベル TB、DPI 経路で既存 UART テストと Linux autotest を回帰、対話イメージの sim | 指摘7〜9,14 |
| G2 補強 | PLL locked・リセット同期・SDC 全クロック・Unconstrained paths=0 を LED の段階で確立 | 後段で STA 不備と論理バグを混同しないため |
| G3 補強 | echo に加え、連続 4KiB 以上の送受信で欠落なし、DTS 由来の divisor で baud を実測 | 指摘8,9 |
| G5.5 新規 | CPU＋M10K ROM/小 SRAM＋UART だけ（SDRAM なし）で hello と riscv-tests 一部 | CPU の Fit/タイミングと SDRAM を切り分ける |
| G6 補強 | 生の SDRAM だけでなく 64bit Membus ブリッジ経由（wmask 256 通り、範囲外アクセスが折り返さずエラーになること） | 指摘3,5 |
| G8 補強 | 読み戻し CRC に加え、`fence.i` 後に**ロードしたコードを I-fetch で実行**、全量 4MB 級の転送（115200 で約6分[推測計算]）の安定性、OE/NACK 再送 | 指摘8,13 |
| G9 補強 | DTS の UART clock・timebase・memory を実機値に合わせたこと、OpenSBI の起動ログの FDT アドレスと PMP 数の確認 | 指摘1,9,10 |
| G10 補強 | 手入力に加え、pyserial スクリプトでコマンド送信と期待出力の照合（自動）。bitstream ハッシュと Git commit を記録 | 再現性 |

---

## 最初に実装する単位（推奨）

**単位1: UART を「16550 レジスタ」と「バイトストリーム I/F」に分割し、合成可能な PHY を追加する。既存 sim は DPI アダプタで同じ挙動を保つ。**（Quartus もボードも不要で、M1 だけで閉じる。Codex の順序案とも一致）

- I/F 案:
  - `rx_byte_valid/rx_byte/rx_frame_err`（PHY→regs、ready なし）。
  - `tx_byte_valid/tx_byte/tx_byte_ready`（regs の TX FIFO→PHY）。
  - `baud_x16_tick`（divisor と基準 enable から生成）。
- テスト項目:
  1. 回帰: `make test-uart test-uart-input test-uart-regs test-uart-tx-irq test-uart-tx-seip test-uart-rx-seip` と Linux BusyBox autotest が DPI アダプタ経由で従来どおり PASS（ユーザー実行）。
  2. TX: 8N1 フレーム、idle High、DLL/DLM＝1,2,27 と基準クロックの組合せでビット時間が理論値±1 クロック。
  3. TX FIFO: THRE 後の 16 バイト連続書込みで欠落なし。満杯で書いたら assert。THRE/TEMT の遷移順序が正しい。FCR bit2 クリア。
  4. THRE IRQ: IER.ETBEI 0→1 で即時、FIFO 空遷移で立つ。THR 書込みと IIR(THRE) 読出しでクリア。IIR の優先度は RX > THRE。
  5. RX: 中央サンプル、baud 誤差±3% で受信成功、0.5 ビット未満のグリッチを棄却、FE、BREAK、連続フレーム。
  6. RX FIFO: 満杯で受信したら OE がセットされ既存データは無傷。LSR 読出しで OE クリア。満杯/空での同時 push/pop。FCR bit1 と push の同時発生。
  7. ループバック: TX→RX を直結し、256 種のバイト値が一致。
  8. 0 除算: divisor=0 のときの定義どおりの挙動、リセット値。
  9. 合成性: 新規 PHY/regs に DPI や `$` タスクがないこと（`ifdef MINTS_SIM` の外に何も残らないことを lint で確認）。

**単位2（直後）**: `RAM_SIZE_BYTES` による定数の一元化と上限デコード＋エラー応答（ハングをなくす）＋sim の可変遅延メモリ（G1.5）。キャッシュ範囲を 16MiB から広げる変更は、さらに別コミットにする。

PMP・キャッシュ縮小・M10K 化は、Quartus の合成ホストが決まって **変更前の Analysis&Synthesis の資源内訳（エンティティ別 ALM）** を取ってから着手する。測定せずに縮小すると効果を評価できない。
