# MiNTs RISC-V CPU — DE0-CV FPGA開発の総括・推奨アーキテクチャ・復旧計画

**基準日**: 2026-11-09\
**対象**: Terasic DE0-CV / Cyclone V E `5CEBA4F23C7N`\
**開発母艦**: Apple Silicon M1 Mac\
**目標**: 既存RV64IMAC CPUをFPGA上で動作させ、JTAGで回路を構成し、UARTでOpenSBI/Linux関連イメージをSDRAMへ送り、実機でLinux 6.12 + BusyBoxを起動する。

> **証拠の区分**: 以下では `[GitHub確認]` / `[当時の会話・作業報告]` / `[未確認]` / `[設計提案]` を区別する。設計提案は過去に成功済みという意味ではない。特に、UART転送が「ホストからの送信完了」なのか「FPGA内SDRAMへの書き込み・照合成功」なのかは未確認。

## 1. 一文での結論

**既存のLinux対応RV64IMAC CPUは維持し、FPGA固有層（同期M10Kキャッシュ・64MB外部SDRAM・UARTブート・ボード用クロック/ピン/STA）を分離して実装する。最初は小容量キャッシュとBTBでFitを優先し、Sv39は残す。宇宙向けRV32IMC/TMR/ECCの研究系統は、実機Linux起動用RV64プラットフォームと区別する。**

## 2. これまでの軌跡と到達点

| 時期・段階 | 成果・判明事項 | 状態・根拠 |
|---|---|---|
| FPGA導入前 | SystemVerilog RV64IMAC、M/S/U、Sv39、PMP、I/D-cache、UART16550、ACLINT、PLIC、OpenSBI→Linux 6.12→BusyBox | `[GitHub確認]` README・Docs・RTL、シミュレーション実績 |
| FPGA導入 | DE0-CV実機入手・LED点灯。基板を5V外部電源で使用 | `[当時の報告]` |
| FPGA合成初期 | 非同期/同サイクルのキャッシュ読み出しなどにより専用RAMを効率使用できず、FF/ALMが増大 | `[当時の報告]` |
| D-cache M10K化 | 同期読み出し、`dcache_fpga_bank`独立モジュール、8行の明示的Byte Enable。Quartus 20.1の単体推論で8,192ビット/バンク、4バンク合計32,768ビットをブロックRAM化 | `[当時の報告]` |
| M10K化テスト | D-cache単体FF 41,051→8,027、部分書込256通り・ストアバッファ・AMOバイパス・無効化・非キャッシュアクセス、LEDプログラム・多くのriscv-testsがPASS | `[当時の報告]`。実機の最終RTLに反映されたかは未確認 |
| 全体Fitter | 一度、31,927 ALM対18,480上限でFit失敗。その後のリソース詳細レポートでは合計必要量27,810 ALMと報告 | `[当時の報告]`。**異なる段階/見積もりの数値を同じ実測値として扱わない** |
| 資源内訳 | キャッシュのタグ周り約10,600 ALM、PMPチェック5か所約4,400、BTB約3,661、MMU本体約1,700。大きな配列と選択MUXが主因 | `[当時の報告]`。カテゴリの合計と総数は完全一致しない概算 |
| 小型化案 | I/D-cache 128→32行（4KiB→1KiB）、BTB 32→8、FPGA初期構成PMP 8→0、**Sv39は維持**。約14,000 ALMを目標とする仮説 | `[当時の報告]`。**縮小構成のFit成功は未確認** |
| UART | UART RX/TX PHY、16550レジスタ、CPU経由UARTのシミュレーションPASS。USB-UART変換器とJP1 GPIOでMac↔DE0-CV実機通信PASSとの報告 | `[当時の報告]` |
| Linux UART転送 | エージェント側が「LinuxイメージをUART経由でメモリに送った」と報告した段階でIntel Macが故障 | `[未確認]`。転送先・全量受信・CRC・SDRAM書戻し・Linux実機起動ログは未確認 |
| 2026-11-09 | M1 Macへ移行、GitHubの`main`にはCPU/Linuxシミュレーション資産が残るが、`fpga/de0-cv/`、`.qsf`、`.sdc`など直近のFPGA用変更は見当たらない | `[GitHub確認]` |

### 重要な教訓

- **機能がシミュレーションで正しいことと、Cyclone VでFit・STAに成功することは別**。
- **RAMのRTLが配列でも、QuartusがM10Kへ推論するとは限らない**。Cyclone V M10Kは同期読み出し対応。Byte Enableは使用可能。
- Quartus 20.1では、今回の特定の`for`ループByte Enable記述は単体推論に失敗し、**8行明示記述は成功**。これは「一般に`for`ループは使えない」という普遍的ルールではなく、当該パターン・ツールでの検証結果。
- 内蔵RAM不足ではなく**ALMの過剰消費**が本質。タグ・BTB・PMP等の実測を優先する。
- 未コミットのFPGA成果が消えた可能性がある。今後は設計・ピン・合成スクリプト・結果・ブートプロトコルをGitに保存する（大量の生成ファイルは除外）。

## 3. 回収できる既存資産

GitHub: <https://github.com/tomamints/mints-riscv-cpu> （2026-11-09に`main`を確認。最後に見つかったコミットは`d8ac2d2` / 2026-11-06）。

**残っている**: `src/`, `rtl/cache/dcache.sv`, `rtl/cache/icache.sv`, `rtl/mmu/`, `platform/riscv_cpu.dts`, `platform/bootrom_linux.S`, `tools/build-opensbi.sh`, `tools/build-linux-busybox-initramfs-image.sh`, `Makefile`, `core.f`, `Docs/LINUX_SETUP.md`, `Docs/REBUILD_FROM_CLEAN.md`, `Docs/LINUX_BASELINE.md` 等。

**見当たらない**: `fpga/de0-cv/`、Quartus `.qsf/.sdc`、`dcache_fpga_bank`、UARTの実機PHY/ブートローダ、SDRAMコントローラ、実機用bitstream。古いIntel Mac、バックアップ、未pushブランチなどに残っていないかは未確認。GitHub READMEにはRV64のLinuxシミュレーション成功が記録され、FPGAのタイミング収束は主張されていない。

**バイナリ復元に注意**: `.gitignore`で`build/`や`*.bin`等は除外されている。OpenSBI、Linux Image、DTB、BusyBoxの生成済みファイルはGitHubに存在するとは限らない。`Docs/REBUILD_FROM_CLEAN.md`に再ビルド順序がある。

## 4. 推奨ハードウェア・アーキテクチャ

```text
                         M1 Mac (host)
      +----------------------------------------------------+
      |  Git/Codex/Verilator  +  Linux RISC-V build tools  |
      |  Quartus: x86_64 Linux環境/別ホストで合成            |
      +-----------+------------------------------+---------+
                  |                              |
     JTAG/USB-Blaster (.sof)          USB-UART 3.3V (TX,RX,GND)
                  |                              |
  +---------------v------------------------------v---------------+
  |        Terasic DE0-CV / Cyclone V E                          |
  |                                                              |
  |  [50MHz clock / PLL / reset / CDC / SDC]                       |
  |             |                                                |
  |    +--------v-------------------------------------------+    |
  |    |  RV64IMAC in-order CPU                            |    |
  |    |  M/S/U, CSR/trap, Sv39+ITLB/DTLB/PTW             |    |
  |    |  I-cache: data/tag M10K可、valid FF              |    |
  |    |  D-cache: data/tag M10K可、valid FF, store buffer |    |
  |    |  BTB/PHT/RAS: 初期小規模、後でRAM化を評価        |    |
  |    |  PMP: 構成選択 (初期0 / 通常8)                  |    |
  |    +------------------+-------------------------------+    |
  |                       | CPU memory/SoC interconnect         |
  |             +---------+-----------+-----------------+      |
  |             |                     |                 |      |
  |      M10K Boot ROM        MMIO UART16550 /       SDRAM ctrl |
  |      + small boot SRAM    ACLINT / PLIC          + bridge  |
  |             |                     |                 |      |
  +-------------+---------------------+-----------------+------+
                                                      |
                                             64MB external SDRAM
                                             x16 bus; Linux実行RAM
```

### 4.1 CPUの構成

- **ISA**: RV64IMAC。F/Dなし、Linuxユーザーランドは`rv64imac/lp64` soft-float。
- **Privilege**: M/S/U、trap delegation、SBI interface。**Sv39は削らない**。現状のCPUパイプラインをそのまま土台とする。
- **初期FPGAビルド**（暫定パラメータ）: I-cache 32行×32B=1KiB、D-cache 32行×32B=1KiB、BTB 8エントリ、PMP 0、Sv39有効、Debug Module無し、write-through D-cache。
- **Linux用/性能用ビルド**: 初期ビルドがFit/STA通過した後、PMP8・キャッシュ容量・BTBを段階的に戻す。変更のたびにメモリ推論・ALM・Fmax・CPIを計測。
- PMP=0は仕様として許容される一方、CSR検出・PMPチェック全箇所・OpenSBIの起動可否を実機/シミュレーションで検証し、保護なしの開発構成であると明示する。

### 4.2 M10Kの設計ルール

1. データRAM・可能ならタグRAM・小さなBoot ROMを**同期読み出し**にする。クロック待ちに対応した`valid/ready`またはrequest/responseをCPU側で扱う。
2. キャッシュデータRAMを独立した**bank module**として実装し、既に成功した**8行のByte Enable明示書き込み**を最初のテンプレートにする。
3. I/D-cacheの**タグ**をM10K化する際は、タグとデータを同時に先行読み出しし、次サイクルでヒット比較する。`cache_hit`でデータRAMの読み出しをゲートすると同時読みができない点に注意。
4. validは一括invalidateしやすいFFなどに残す。RAMの同一アドレス同時読み書きの結果を不定として扱う/明示的に回避し、シミュレーションassertionを残す。
5. Quartusレポートで**推論されたRAMのビット数、FF/ALM、メッセージ**を記録する。推論成功は単体だけでなくCPU全体の合成でも確認。
6. パラメータ縮小で配列のindex/tag幅を変更した後、refill・store buffer・invalidate・`fence.i`・branch predictor等の回帰を必須にする。

### 4.3 メインメモリ：外部SDRAM

DE0-CVは**64MB（32M×16）SDRAM**を搭載。内部M10K（数百KiB規模）とは別の物理デバイスであり、Linuxの実行メモリには原則SDRAMを利用する。

- **SDRAM controller**: POWERUP初期化（PRECHARGE / refresh mode等）、ACTIVATE/READ/WRITE、CAS遅延、リフレッシュ、読み書きバイト制御、CPUの64-bit mem busとのx16幅変換を担当。
- **メモリブリッジ**: `req_valid/ready`, `rsp_valid/data/error`、必要に応じてID/順序を管理。I-cache、D-cache、ページテーブルウォーカ、UART loaderのアクセスを仲裁。ブート時の競合は避ける。
- **クロック**: ボード50MHz基準。SDRAM参照デザインは別クロック生成例あり。CPU初期20MHzとSDRAMクロックを別ドメインにするなら、明示的CDC（非同期FIFO/ハンドシェーク）とSDCが必要。周波数・位相条件はコントローラの仕様と実測で確定。
- **検証順**: CPU接続前に、UARTやLEDからアクセスできるSDRAM read/write testerで walking-1/0、address alias、バイトマスク、広域パターン、refresh長時間テストを行う。

### 4.4 ブートROMとUARTロード方式（設計提案）

**Linuxを転送するには、送信相手となる受信ローダーと書き込み可能なメモリが必要。UART PHY/16550単体ではSDRAMへLinuxは入らない。**

推奨は、FPGA内の**小容量M10K Boot ROM**で動くM-modeプログラムから開始する方法。

1. リセット解除、PLL/SDRAM初期化完了を待ってBoot ROM実行（リセットベクタはSoCで定義）。
2. UART16550を115200 8N1で初期化。Macの転送ツールと同期する。
3. Macから`Magic + destination address + length + payload + CRC`等のフレームを送る。範囲・重複・境界チェック、分割転送とACK/NACKを設ける。
4. LoaderはSDRAMへ書き込み、**SDRAMから読み戻したCRC**で整合性を判定する。Macの送信完了だけでは成功扱いにしない。
5. OpenSBI `fw_jump.bin`、Linux `Image`（initramfs組み込み）、DTBを合意済みアドレスへロードし、`GO`要求でOpenSBIのエントリへ制御移行。
6. OpenSBI→S-mode Linux→BusyBox `/ #` までログを記録。

**別案**: CPU停止中に独立したUART-DMA受信FSMがSDRAMをロードする。CPU側のBoot ROM設計が難しい場合の代替。ただしメモリ所有権・CPUリセット制御が増えるため、まずはソフトウェアローダーを第一候補とする。

### 4.5 メモリマップ案

| 領域 | 候補アドレス | 注意 |
|---|---|---|
| FPGA Boot ROM（M10K） | `0x0000_0000`近傍 | **新規提案**。既存CPUのreset vector変更が必要。Boot ROMはLinux SDRAM領域と重ねない。 |
| Boot作業用SRAM（M10K） | `0x0001_0000`近傍 | 新規提案。サイズ・スタック・用途は要設計。 |
| ACLINT | `0x0200_0000` | 既存SoCとの互換性維持 |
| PLIC | `0x0c00_0000` | UART割り込み線の設定は既存設計と合わせる |
| UART16550 | `0x1000_0000` | 実機JP1へ接続 |
| Debug MMIO | `0x4000_0000` | 任意。RISC-V Debug Moduleとは別 |
| **SDRAM 64MiB** | **`0x8000_0000`–`0x83ff_ffff`** | 提案する連続物理RAM領域 |
| OpenSBI | `0x8000_0000`付近 | `fw_jump`のリンク・エントリと整合させる |
| Linux Image | `0x8020_0000`付近 | 従来の位置を保持する案。サイズ・配置確認 |
| DTB | `0x83f0_0000`付近 | **新規候補**。最終的なカーネル・initramfs使用量、予約領域と衝突しないか要検証 |

GitHubのシミュレーション環境はRAM 128MiB（`0x8000_0000`–`0x87ff_ffff`）、DTB `0x87f0_0000` を想定している。**このDTBアドレスは64MiB SDRAMの範囲外なので、そのまま実機へ持ち込めない。** `platform/riscv_cpu.dts`の`memory/reg`、OpenSBI・カーネル・DTB、DTBポインタ、UARTベース/IRQ、`timebase-frequency`を一括して整合させる。

### 4.6 UART/JTAGの物理接続

- **JTAG**: ボード内蔵USB-Blaster。`.sof`を書き込むための経路。自作CPUのDebug Moduleは後回し。
- **UART**: FTDI TTL-232R-3V3など**TXD/RXD信号が3.3V TTL**のUSB-UARTアダプタ。JP1の**8番＝FPGA TX（FTDI黄RXD）**、**10番＝FPGA RX（FTDI橙TXD）**、**12番＝GND（FTDI黒）**。JP1の**11番は5V**、FTDIの赤い電源線も使わない。電源を落として配線・ピン1確認。
- Quartusの`VIRTUAL_PIN`設定は解析専用。**実機bitstreamではピン番号・3.3-V I/O規格の制約が必要**。
- RXDはFPGAの非同期入力なので2段FF同期化を維持。SDCの例外は実際のCDC位置に限定し、STA対象外の経路を確認する。TXDレジスタからピン出力の物理制約も検討。

### 4.7 タイミング・資源設計

- `quartus_map`→`quartus_fit`→`quartus_sta`。レポートで**ALM、FF、M10K、Fmax、Setup/Hold worst slack、Unconstrained paths、クリティカルパス**を記録。
- 初期CPUターゲットは20MHz（50ns周期）の**仮目標**。タイミング収束した最大周波数ではない。
- 18,480 ALM上限ギリギリを目標にせず、**目安として70–80%程度を狙う**。Fit余裕は周辺・コントローラ・追加検証回路にも使う。
- 過去のALM 31,927と27,810は別レポート由来。`28K − 14K`という単純計算は合成の最適化・パッキングの影響を無視するため、**14K ALMは予測に過ぎない**。
- `Fmax`向上とCPU `CPI`悪化はトレードオフ。実行命令数/秒 = `Fclk/CPI`。同期RAM化・キャッシュ縮小後はベンチマークでCPI測定する。

## 5. 開発ホスト構成（M1 Mac）

| 作業 | 推奨環境 | 理由・注意 |
|---|---|---|
| Git・Codex・RTL編集 | macOS (arm64) | ソース管理と編集をMacで行う |
| RTL単体/CPUシミュレーション | macOS arm64のVerilator / Python / Icarusなど | ネイティブ実行を優先。Linux RISC-Vクロスツールは必要なものだけ用意 |
| Linux/OpenSBI/BusyBoxビルド | arm64 Linuxコンテナまたはネイティブクロス環境 | `rv64imac/lp64`、OSビルド依存性、ツールバージョンの再現性を保つ |
| Quartus Prime Lite 20.1 | **x86_64 Linux** | Apple Siliconネイティブは非対応。M1上の`linux/amd64`エミュレーションは実行・速度・メモリを**検証必須**。利用可能なら実x86_64 Linux機/リモート環境がより確実 |
| DE0-CVプログラム/JTAG | Mac上のopenFPGALoaderなど | USB-BlasterをMacホストで扱う。Docker側へ安易にUSBパススルーしない |
| UARTローダ・コンソール | macOSのPython/pyserial、screen等 | `/dev/cu.usbserial...`を確認。シリアルポートは1プロセスで占有管理 |

公式情報: Quartus Lite 20.1 Linux版はAltera配布。openFPGALoaderはHomebrewでApple Silicon対応。Dockerのamd64エミュレーションは実機条件で性能・互換性に差がある。

## 6. 具体的な開発マイルストーンと合格条件

| Gate | 作業 | PASSの条件 | 依存 |
|---|---|---|---|
| G0 | GitHub復元・別ブランチ作成 | ソース取得、コミット記録、既存RTLを保全 | なし |
| G1 | M1シミュレーション | 基本のVerilatorビルド、UART/rv64命令テストPASS | G0 |
| G2 | Quartus最小プロジェクト | LED動作`.sof`生成、USB-Blasterで書き込み、基本STA | G0 |
| G3 | USB-UART実機 | JP1のTX/RX/GND 3本、115200 8N1、エコーPASS | G2 |
| G4 | FPGA同期RAM | 8,192-bit bank単体＋4bankでM10K推論、全256マスク、read-during-write assertion PASS | G1, G2 |
| G5 | CPU小型構成Fit | I/D-cache32行、BTB8、PMP0、Sv39維持。ALM/M10K/Fitter/STAをレポート | G4 |
| G6 | 外部SDRAM単体 | 64MiBのaddress/data/byte-mask/refreshテストPASS、CDC含むタイミング検証 | G2 |
| G7 | CPUからSDRAM | M-modeプログラムでSDRAMをread/writeし内容を照合 | G5, G6 |
| G8 | UART loader | 複数チャンク送信、SDRAM読み戻しCRC、異常時再送・範囲チェックPASS | G3, G7 |
| G9 | OpenSBI起動 | JTAG起動後UARTコンソールでOpenSBIの識別ログ、M→S handoffを確認 | G8 |
| G10 | Linux+BusyBox | RAM 64MiB・DTB修正、Linux bootログ、`/ #`相当のシェルでコマンド実行 | G9 |
| G11 | 性能/耐故障研究 | CPI/Fmax/ALM等のベースラインを固定した後、ECC・時間冗長・選択的TMRを別構成で評価 | G10 |

**重要**: G6のSDRAM単体テストはG5 CPU全体のFitと並行して進められる。Linuxを早く試したいからといってRAMテストを飛ばすと、Linux起動不良の切り分けができなくなる。

## 7. 推奨ディレクトリ設計（Gitに残す）

```text
fpga/de0-cv/
  README.md                   # 配線、クロック、手順、前提
  quartus/
    de0_cv.qpf
    de0_cv.qsf               # DEVICE、TOP、全ピン/I/O制約
    de0_cv.sdc               # clocks、CDC、タイミング制約
  rtl/
    de0_cv_top.sv            # ボード接続とreset/PLL
    clock_reset.sv
    sdram_controller.sv      # 独立してテスト可能
    sdram_bridge.sv          # CPU busとx16 SDRAM
    boot_rom.sv
    boot_sram.sv
    uart_phy.sv              # 既存UARTから必要機能を復元
    cache_ram_bank.sv        # 合成実績に基づくM10Kモジュール
  boot/
    bootloader.S / bootloader.c
    linker.ld
    protocol.md              # UARTフレーミング・CRC・再送
  host/
    uart_loader.py
  tb/
    tb_cache_ram.sv
    tb_uart_phy.sv
    tb_sdram.sv
    tb_uart_loader.sv
  scripts/
    synth_ram_probe.sh
    fit.sh
    timing.sh
    report_resources.py
  reports/README.md          # 比較に必要な数字と参照を保存
```

**配置は例**。既存RTLとの依存関係が最小になるよう、導入時に名前を決定。Linux用ビルド/シミュレーションの既存`src/`/`rtl/`を勝手に削除・改変しない。Quartusの大型生成物や一時ログはGit追跡から除外し、結論・再現用スクリプト・要約レポートを保存。

## 8. 移行時の優先順位と保留事項

### 直ちに確定させるもの

1. M1 Macで取得できるGitコミットを**基準版**として固定（`d8ac2d2`が2026-11-09確認時の最新）。
2. 旧MacのFPGA追加コードがバックアップ・ディスク・クラウド・未pushブランチ等に残っているか探索（可能な範囲）。
3. ボード最小top、GPIO/JTAG、PLL/SDCを作って実機動作を再現。
4. **M10K推論テストを単体で再実行**し、旧成功パターンを再構築。最初からキャッシュ制御全体を大規模に変更しない。
5. SDRAMテストのため、TerasicのDE0-CV SDRAM RTL Testの提供ソース/タイミング例を参考にしつつ、利用ライセンス等を確認する。

### まだ決め打ちしないもの

- 直近の未保存RTLの実際の内容（復元できない場合は再実装）。
- UART受信がSDRAMまで確実に書き込まれたか、Mac送信完了だけか。
- 20MHzで動作するか、縮小版が本当に14K ALMになるか。
- 64MiBで既存のLinux Image/initramfsが収まるか（バイナリ実サイズを測る）。
- SDRAM制御を自作IPにするか、参考設計を採用するか。
- PMP=0でのOpenSBI/S-mode起動の実測結果。

## 9. 長期の宇宙向け耐故障研究との切り分け

現在のLinux起動プラットフォームは**RV64IMAC・実機bring-up基盤**。別の研究テーマである**RV32IMC・非パイプライン・Temporal redundancy・選択的TMR・ECC**を今すぐ混在させると、資源不足やタイミング異常の原因分析が難しくなる。まず動くRV64プラットフォームのメモリ系と測定手法を確立し、耐故障コアは**独立構成/別ブランチ**で同じGPIO/UART/SDRAM/計測インフラを再利用できるよう設計する。

## 10. 復旧作業の最初の実行指示（Codex向け）

1. 作業対象を`https://github.com/tomamints/mints-riscv-cpu`のクローンに限定し、既存コード・変更点を保護した新ブランチを作る。
2. `uname -m`、macOS、Homebrew、Verilator、Docker、USB-Blaster、FTDIの認識状態を収集。
3. リポジトリ内のCPU、I/D-cache、MMU、UART、Linux生成スクリプトを監査し、**GitHub版との差分・不足するFPGAファイル**を一覧化。
4. Quartus 20.1を実行する方法（M1上amd64コンテナか、別のx86_64 Linuxホスト）を実測で確認。実行が不安定なら方式を固定せず代案を報告。
5. FPGA用`de0_cv_top`最小LED/JTAGを構築し、UART PHY echoとRAM bank単体試験を設計。**この段階ではCPU全体やLinux用RTLを全面書き換えない。**
6. 各GateでRTL、再現コマンド、PASS/FAIL、ALM/M10K/Fmaxを報告してから次に進む。

## 参考リンク

- GitHub: <https://github.com/tomamints/mints-riscv-cpu>
- GitHubのリビルド手順: <https://github.com/tomamints/mints-riscv-cpu/blob/main/Docs/REBUILD_FROM_CLEAN.md>
- Terasic DE0-CV製品仕様: <https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=167&Language=English&No=921&PartNo=2>
- DE0-CV User Manual: <https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5740/DE0_CV_User_Manual_112.pdf>
- Cyclone V Embedded Memory Features (M10K, Byte Enable): <https://docs.altera.com/r/docs/683375/current/cyclone-v-device-handbook-volume-1-device-interfaces-and-integration/embedded-memory-features>
- Quartus Lite 20.1 Linux版: <https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-20-1-linux>
- openFPGALoader Homebrew: <https://formulae.brew.sh/formula/openfpgaloader>
- Terasic DE0-CV SDRAM RTL test reference: <https://yamin.cis.k.hosei.ac.jp/lectures/projects/figs/doc-us-dsnbk-42-1504012210-de0-cv-user-manual.pdf>
