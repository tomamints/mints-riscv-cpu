# UART PHY 実装前レビュー（Codex）

日付: 2026-11-09。対象: `fpga/de0-cv/UART_DESIGN.md` と既存のRTL草案4ファイル。
レビュー担当・着手判断: Codex。実装担当: Claude。

判定: **下記2点を修正する条件で第1段階の実装へGO**。
今回のレビューではコードを読んだだけで、UARTの論理検証・合成は未実施。

## 着手時に修正する点

1. **BREAKを9.5bitで確定しない。** 設計案は16550の1文字分のLowより短いと
   自ら記載している。0x00でstop中央がLowでも、10bit未満でHighへ戻る場合は
   framing errorのみとし、BREAKにしない。連続Lowが少なくとも10bit続くまで
   判定を遅らせる。イベントは1回、data/FE/BIを同時に出す。通常フレームの
   stop中央での受信は維持し、Low保持中の再アーム抑止も維持する。
2. **divisor=0中の過去のHighをstart資格として保持しない。** 草案の
   `uart_rx` はdisabled中にLowになってもarmedが残るため、Lowの途中で
   有効化するとstartとして受理しうる。disabled中はarmedを落とし、有効化後に
   Highを観測してからLowへの移行を受け付ける。mid-frame divisorラッチは維持。

## 承認する設計判断

- TX/RX独立の位相生成、フレーム開始時のdivisorラッチ、生成クロックを作らない。
- TXのready/valid、stop完了後1clkの余裕、RXの2FF同期と中央サンプル。
- 最大divisorと不正パラメータ、reset、divisor変更を検証対象に含める。
- 独立したホスト側シリアルモデルで検証し、loopbackだけに頼らない。
- この段階ではCPU・16550・FIFO・IRQ・DTSへ接続しない。

## 次のレビュー条件

Claudeは上記を反映したRTL、テストベンチ、filelistと実行手順を作成する。
テストには短いLowと10bit境界のBREAK判定、disabled中のLow保持からの
有効化、次の正規フレームの受信を追加する。
Codexが差分と期待値を確認するまで、UARTのコンパイル・lint・シミュレーションは
実行しない。既存RTL草案は完成品として扱わない。

## 修正版のRTL/TBレビュー

ClaudeのRX_BRK追加とdivisor=0時のarmedクリアをコードで確認した。
独立したホストモデル、全256値、baud差、reset、divisor変更、BREAKの閾値と
再アームを扱うテスト設計は承認する。

ただし `tx_decode` のstop長チェックにはTBの誤りがある。
`tx_fall_cnt` はstartだけでなくデータ内の立下りも数えるのに、stopの最後で
start前の値+1と比較しており、正常な0x55等を失敗扱いにする。
stop中央での立下り数を保存し、それ以降のstop終端までに新たな立下りが
ないことを検査するよう修正する。データ内エッジ数チェックと、0x55を使う
境界時刻・フルstop期間のチェックは残す。

この限定修正を反映した後、50MHzと20MHzのlint・コンパイル・単体検証へGO。
その他の機能仕様変更や期待値の緩和は、原因と根拠を提示して再レビューする。

## 検証結果の受入れ

Claudeが限定修正を実施し、Codexがstop判定の差分・runner・警告抑制の範囲・
保存された結果ログを確認した。観測専用divisor信号のUNUSEDSIGNAL抑制は
その宣言だけに限定され、TBの可変#0遅延は`--sched-zero-delay`で扱っている。
機能仕様やデータ比較の期待値を弱める修正はない。

- Verilator 5.046、RTLの`-Wall` lint: 警告0。
- 50MHz / 20MHzとも`UART_PHY_TB_PASS`、ビルド警告0。
- クロックごとにRX 1,422イベント、loopback 512件、TX 65転送。
- 根拠: `build/test/uart/{runner,lint,run_50m,run_20m}.log`。
- 未実施: TB全体の`-Wall`、ミューテーション、Quartus、実機、FIFO/IRQ/16550接続。

**PHY単体のシミュレーション結果を受入れ。次段階は16550/FIFO接続の設計案レビュー。**
