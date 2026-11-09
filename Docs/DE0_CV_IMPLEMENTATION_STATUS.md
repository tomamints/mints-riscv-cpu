# DE0-CV 実装・検証の進行記録

更新日: 2026-11-09

## 到達目標と基準

M1 MacのUARTターミナルから、DE0-CV上のMiNTs RV64IMACで動く
Linux / BusyBoxシェルへコマンドを送り、FPGAからの実行結果を受け取る。
JTAGは回路の構成、UARTはイメージのロードとLinuxコンソールに使用する。

方針の出典は
[復旧計画](MiNTs_DE0CV_M1_FPGA_Architecture_Recovery_Plan.md)。
M1上のVerilatorによるLinux 6.12 / BusyBox自動テストは確認済み。
Lチカの合成・Fit・STA・SRAM書込み・実機点滅はM1で確認済み。
CPU/Linux全体のFPGA合成と実機起動は未確認。

作業開始時のGit基準は `3374f8c`。実装ブランチは
`fpga/de0-cv-bringup`。既存Linuxシミュレーションを回帰基準として維持する。

## コードから確認できた差分

| 対象 | 現状 | 実機化に必要な作業 |
|---|---|---|
| UART | `src/uart_ns16550.sv` はDPI入力と `$write` 出力。RX/TXピンなし | バイト単位のready/valid境界、実UART PHY、FIFO、送信状態と割り込みの整合 |
| UART送信状態 | LSRのTHRE/TEMTは常時セット、送信完了イベントはシミュレーション向け | FIFO空とシフトレジスタ空を区別し、満杯・送信中・割り込みを定義 |
| 主記憶 | `src/top.sv` 内の `memory` 配列で128MiBをモデル化 | 外部SDRAMコントローラと64bit→16bitブリッジ、可変応答遅延への対応 |
| メモリマップ | DTSは128MiB、DTBは `0x87f00000` | 64MiBの範囲内へDTBを移し、DTS・ROM引数・RAM生成を一致させる |
| RAMデコード | `src/mmio_controller.sv` はRAM開始以上をRAMとして扱う | 実容量の上限、範囲外要求、上位アドレスの折り返しを検討 |
| RAM幅の単位 | `RAM_ADDR_WIDTH=24` は配列の64bitワード数。キャッシュの範囲判定は `1 << RAM_ADDR_WIDTH` を使用 | バイト容量・ワードアドレス幅・キャッシュ可能範囲を混同しない。既存挙動への影響を別途レビュー |
| リセットベクタ | `src/eei.sv` の `INITIAL_PC` はROMの `0x1000` | 最初は既存ベクタを維持。ROMを `0x0` へ動かす必要性は未確定 |
| キャッシュ | `rtl/cache/` にデータとタグ配列。同期RAM専用bankは未実装 | RAMポートとサイクルを設計し、byte enable・invalidate・AMO・refillを検証 |
| 合成用ソース | `core.f` はDPIを含む `src/util.sv` とシミュレーション用topを参照 | FPGA用filelist/topを分離し、合成不能構文と性能カウンタの扱いを確認 |
| ボード用資産 | このクローンにQuartusプロジェクト、SDC、SDRAM制御、UART PHYなし | ボード層と再現可能な合成・レポート手順を追加 |

## 実装前レビューの対象

Codexが管理・調査・方針決定と実装前レビューを担当し、Claudeが具体的な
実装案とコードを作成する。Codexが着手を判断し、実装後の差分と検証結果も確認する。
最初のClaudeによる監査は参考レビューとして保持する。
シミュレーションのPASSと、RAM推論・Fit・STA・実機のPASSを分けて記録する。

最初の設計判断:

1. Sv39、M/S/U、現在の命令セット、Linux回帰基準を維持する。
2. 最初のRTL作業はUART PHYと16550へのバイト接続の仕様確定を候補とする。
   RXの同期化、FIFO満杯、同時push/pop、baud divisor、THRE/TEMT、割り込み、
   reset、端末改行とバイト保持をレビューする。
3. LED/JTAG、UART echo、SDRAM単体試験をCPU全体の実機起動より先に通す。
4. CPU接続前に、要求がreadyになるまでの保持と、書込みを含む応答の条件を
   SDRAMブリッジで明確にする。範囲外ロードを成功扱いにしない。
5. キャッシュやBTBの容量縮小はパラメータ化と測定を伴わせる。
   PMP=0は暫定候補のままとし、CSR・権限チェック・OpenSBIを含む一貫した
   仕様がレビューできるまで無効化しない。
6. UARTロードの成功条件は、全量受信とSDRAM読み戻しCRCの一致。
   送信完了だけでLinuxロード成功としない。
7. 最終ゲートは実UARTからの対話シェル操作と自動テストの両方。

## 現在の環境と次のゲート

- Apple M1 / macOS 15.7.5、Docker ARM64 Linux、Verilator 5.046を利用可能。
- 調査時のUSB一覧にDE0-CV / USB-UARTはなく、対応する `/dev/cu.*` も未検出。
- Quartus / openFPGALoaderはPATH上に未検出。
- M1でのQuartus x86_64実行方法は未検証。別ホストの利用可否をユーザーへ確認中。
- Claudeの[実装前レビュー](reviews/DE0_CV_PRE_IMPLEMENTATION_REVIEW.md)は条件付きGO。
  以下のC1〜C4を採用して、UARTを段階的に実装する。

## レビュー後の決定

- **C1 / PMP**: 現在の8エントリを維持する。0へ減らす場合は「未実装」と
  「実装済みだが一致なし」を区別し、CSRとS/Uアクセスの挙動も変更・検証する。
- **C2 / 容量**: 後続変更でバイト容量を正とした共通設定を導入する。
  DTS・ROM引数・ローダ・デコード上限を同一設定から導出する。
  キャッシュ範囲を広げる変更は単独で扱い、Linux回帰を必要とする。
- **C3 / バス**: 1 outstanding、受理後1サイクル以降の応答、書込みにも1回の
  完了応答を要求する。SDRAM導入前に固定seedの可変遅延モデルで回帰する。
  範囲外アクセスのハング解消は必要だが、「ゼロを返して成功」は最終仕様に
  採用しない。access-fault経路と診断方法を別途設計レビューする。
- **C4 / UART**: 16550レジスタ、FIFO、実PHY、DPIアダプタを分離する。
  TX FIFOは16段、THREはFIFO空、TEMTはFIFO空かつシフタ空。
  RX overflow / framing / break、FCR clear、同時push/pop、IRQ優先度、
  基準クロックとDTSの一致を仕様化する。

最初のコード変更（UARTの第1段階）は独立した8N1 PHYとbaud生成器。
既存CPU/UARTモデルへの接続とFIFO/16550分離は次段階とし、今回は変更しない。
レビューで指摘された送信欠落を、PHYだけで解決した扱いにはしない。
コードとテストベンチをCodexがレビューし、必要な修正後に初めて論理検証を実行する。
UART全体の完了条件は、FIFO/IRQを含むMMIO接続と既存回帰・対話シェルである。

## 並行作業

- Codex: `fpga/de0-cv/blink/` のLチカとボード書込み環境。
  Verilatorで実分周値の周期・reset・分周1/3の境界をPASS。
- Claude: UART設計案とRTL/TB。Codexの
  [事前レビュー](reviews/UART_PHY_DESIGN_REVIEW_CODEX.md)に従って実装中。
  Codexが修正RTLとTBをレビューし、TXデコーダの誤判定を修正する条件で
  検証を承認。RTLの`-Wall` lintと50MHz/20MHz単体テストがPASSし、
  Codexがコード差分とログを確認済み。16550/FIFO/IRQ接続と実機UARTは未実施。
- USB-BlasterをMacのIORegistryで認識済み。合成用Quartusの取得が必要。
  native openFPGALoader v1.2.0を構築し、実機JTAGからCyclone V A4の
  IDCODE `0x02b050dd`を連続して読み取れた。Flash/SRAMへの書込みは未実施。
  amd64 Dockerの`uname -m`は実行できたが、Quartus本体の実行は未確認。
  LチカのFit/STAと実機点滅は、公式インストーラーの取得後に確認する。

UART検証は `bash tools/test-de0cv-uart.sh` で再実行できる。
各クロックでRX 1,422イベント（FE 6、BI 2）、loopback 512バイト、TX 65転送を
確認。TXの理想境界からの最大偏差は50MHzで19.7ns、20MHzで48.6nsで、
いずれも1クロック未満。根拠ログは `build/test/uart/`。
テストベンチ自体の全警告lintとミューテーションテストは未実施。
このPASSはQuartusの合成・STAや実ボードの信号品質を保証しない。

## 一次資料

- [Terasic DE0-CV公式仕様](https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=167&Language=English&No=921&PartNo=2)
  は対象デバイスと64MB / x16 SDRAMを示す。
- [Quartus Lite 20.1 Linux公式配布ページ](https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-20-1-linux)
  には20.1.0.711の本体とCyclone V用デバイスパッケージがある。
  ダウンロード経路は認証ページを指しており、インストール可否と実行可否は別途確認する。

## 2026-11-09 追加チェックポイント

- M1 + amd64 Docker + Quartus Lite 20.1.0.711でLチカFull Compilation成功。
  50MHz全4コーナーのSTA成功、SOF→RBF変換、Mac native openFPGALoaderで
  SRAM書込み100% / Done / exit 0。ユーザーが実機点滅を確認した。
  [手順・障害対策・チェックサム](../fpga/de0-cv/blink/QUARTUS_M1_SETUP.md)を保存。
  上記の古い「Quartus取得待ち」「別ホスト確認中」の記述はこの結果で更新される。
- 共通Cテスト起動基盤を復元し、旧UARTの基準は2 PASS / 4 TIMEOUT。
  詳細は[基準記録](../fpga/de0-cv/UART_C_TEST_BASELINE.md)。
- 新規16550 regsをCodexが差分レビューし、TBの競合を修正後に単体検証をGO。
  機能12/12 PASS、意図的TX overflowは期待非ゼロ終了。
  新規RTL警告0。依存する既存共有ファイルのlint警告66件は残る。
  regs+PHY結合、SoC接続、C/Linux回帰は未実施。

## G3 UART physical communication checkpoint (2026-11-09)

PHY+FIFO echo project passed simulation, Quartus Fit and all-corner STA.
After user wiring JP1-8/10/12, FTDI TTL232R-3V3 (0403:6001) was detected.
Native SRAM programming succeeded on retry (first JTAG scan timed out).
Host echo test at 115200 8N1 passed single/all256/chunk4096/stream4096/silence,
exit 0. See `fpga/de0-cv/uart_echo/README.md` for exact commands and limits.
LED observation and optional BREAK diagnostic are pending; CPU/16550/IRQ/Linux
on the physical FPGA remain unverified. Next major work is G4 M10K banks and
G6 SDRAM architecture/standalone testing, followed by CPU resource reduction.
