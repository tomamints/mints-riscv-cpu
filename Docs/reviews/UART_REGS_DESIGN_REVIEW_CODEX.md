# UART 第2段階 実装前レビュー（Codex）

2026-11-09。対象: `fpga/de0-cv/UART_REGS_DESIGN.md`。
判定: **仕様修正が必要。先行するテスト基盤の復元だけGO。regs RTLはまだ着手しない。**

## 重大な修正: FIFO無効時の動作

FCR[0]を無視して常に16段として動かす提案は、現段階では採用しない。
Linux 6.12の`serial8250_console_write()`はソフトウェア上のFCRに加え、
`port->state`と`TTY_PORT_INITIALIZED`も確認してFIFO経路を選び、port lockも取る。
`serial8250_clear_and_reinit_fifos()`はclear後にFCRを再設定する。
`clear_fifos()`の一部分だけから常時16段が必要とは結論できない。

実装は物理16段、FIFO無効時の有効容量はTX/RXとも1とする。
FCR[0]とIIR[7:6]と実際の容量を一致させる。Linuxで問題が出た場合は、
FCRへの実際のアクセス列とシリアル出力を取得して原因を検証する。

根拠: ローカルLinux 6.12の`drivers/tty/serial/8250/8250_port.c`と
[TIの16550系FCR説明](https://www.ti.com/lit/ds/symlink/tl16c550c.pdf)。
TIの説明はFCR[0]による有効化と、切替時のFIFOクリアを定義する。

## 未決定8項目への判断

1. FCR[0]=0の書込みではclear/trigger等を無視する。ただしenableの切替による
   FIFOクリアは有効。RX clearと新規pushが同時ならclear後に新しいバイトを残す。
   TX clearの受理エッジではPHYへの新規handoffを抑え、既存の送信中フレームは止めない。
2. ETBEI=0ではpendingを0へ。書込み後IERを優先して判定する。
   ETBEI=1の場合は、新しい空遷移・enable事象がIIR readによるclearに勝つ。
   THR writeと最後のpopが同時でFIFOが空にならない場合はsetしない。
3. DLAB中の新規TX開始を止める案を採用する。進行中フレームは旧divisorで完了。
   これは8N1向けの実装判断として明記し、RXへのdivisor更新と組み合わせた試験を行う。
4. MCR loopbackは今回の範囲外。保存のみ、送受信・モデム線のループバックはしない。
   未対応機能と明記し、NS16550全機能互換を主張しない。Linux固定型probeだけでなく
   このボードのドライバ設定を前提にする。
5. FE/BIはエントリに付随し、LSR readで現在headの表示をackする方式を採用。
   新headが同時に生じた場合はackを継承しない。OEはstickyで、新overrunがclearに勝つ。
   LSR[7]の意味はhead ackとFIFO内の原フラグの関係を明示してから実装する。
6. 共通テストコードを`tb/sw/common/`へ復元し、Makefileの参照を変数化してよい。
   まずCテストもUART RTLも変更せず旧挙動の結果を記録する。
   IERの0x55→0x05の期待値修正は仕様に沿うが、基準記録後の別変更にする。
7. sim backendの速度指定は採用可。ただし最初のregs/FIFO単体試験で
   backpressureとOEを独立に検証し、CPU試験用の強制入力plusargは必要性が出てから追加する。
   DPI入力に1サイクルのイベント遅延がある場合は、その予約分をrx_space判定に含める。
8. regs+PHYのビットレベル結合試験は必須。PHY経由のフルLinux起動は追加ゲートとし、
   最初の必須条件にはしない。通常のLinux autotestと対話RX確認はSoC変更後に必要。

RX trigger=1固定・timeout未実装は暫定の対応範囲として許容する。
トリガ設定を読み返せても動作には反映しないことを明記する。
上限違反を黙って成功扱いにせず、overflowは診断できるようにする。

## 先行作業のGO範囲

- `tb/sw/common/{bootrom.S,entry.S,link.ld}`を新規作成する。
  ROMは`0x80000000`へジャンプ、entryはgp/spを初期化しBSSをクリアしてmainへ。
  mainが成功通知なしで戻った場合はdebug MMIOへ失敗を通知して停止する。
- MakefileのCテストとbootrom参照を共通ディレクトリ変数へ変更する。
- UART RTLと既存Cテストは変更せず、UART系ターゲットを実行する。
  PASS/FAIL/TIMEOUTをログの成功・失敗マーカーと終了コードから判定する。
  想定していたIIRの不一致も失敗として記録し、テスト期待値を緩めない。
- RTLの追加実装や、トラップハンドラ等の既存Cテスト修正が必要なら報告して再レビュー。

戻り値だけでテスト成功としない。有限サイクルでPASSが出ず終了した場合は未完了。

## 先行作業の受入れとregs単体の着手GO

復元したROM/entry/linker、Makefile参照、runnerと基準記録をCodexが確認した。
2 PASS / 4 TIMEOUTの記録を受け入れる。TIMEOUTにはIIR不一致によるfail()到達が
含まれ、現debug MMIOが偶数2を終了扱いにしない制約も明記されている。
Linux起動やCPU本体の変更は含まれていない。

以下の仕様整合を反映する条件で、**新規regsと単体TBの作成のみGO**。
sim wrapper/core.f/既存Cテストへの接続と、実機/合成への組込みは次のゲート。

- 設計書4.3の`<16`を`<cap`に統一し、clear時は新しい容量を使う。
- MCR loopbackは保存だけなので、TX validをMCR[4]で止めない。
- DLAB中のTX停止とTX clearのhandoff抑止は、共通regsのtx_validでも保証する。
  従ってsim backendにも同じ規則が適用される。未接続のhandoff_pendingは導入せず、
  同期valid/readyとPHY busyでTEMTを定義する。
- TX満杯でも同時にpopすればTHR writeを受け入れる（pop後の容量で判定）。
- LSR7の「原エラー数からheadのack分を引く」定義を承認し、counterの範囲を検査する。
- バス読み出しは更新前の状態を返す。LSR readと新head/新overrunの競合をTBで確認する。

テスト設計と実装の差分をCodexが読むまで、今回の新規regsのlint・コンパイル・
論理検証は行わない。TX overflowの意図的な異常試験はsticky診断で検査し、
sim `$error`を有効にする別プロファイルがある場合は期待非ゼロ終了として分ける。

## regs/TB差分レビューと単体検証GO

Codexが新規RTLとTBを読んだ。容量1/16、pop後容量、clear時handoff抑止、
head ackと原エラーカウンタ、更新後IERによるpending判定を確認した。
TBのposedgeでの刺激変更・queue検査はmonitorと競合するため修正を要求し、
negedgeへの統一を再レビューした。IIR read＋last pop、IER=0＋last pop、
MCR[4]保存中の実handoffの追加も確認した。

新規regsのlint・単体シミュレーションと専用runner追加だけGO。
通常12ケースと、overflowで非ゼロ終了する診断プロファイルを分けて記録する。
既存UART/CPUへの接続、既存Cテスト変更、実機への組込みはまだ承認範囲外。
