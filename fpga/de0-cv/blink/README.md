# DE0-CV Lチカ

50MHzのボードクロックでLEDR0を0.5秒ごとに反転する（1秒周期、50% duty）。
KEY0を押すとLEDを消灯してカウンタをリセットし、離した後は2段同期で再開する。
この回路はCPU、SDRAM、UARTを使わない。

## 接続

[Terasic DE0-CV User Manual, May 4 2015](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5740/DE0_CV_User_Manual_112.pdf)
のTable 3-2 / 3-4 / 3-6で確認した割り当て:

| 信号 | FPGA pin | 用途 |
|---|---|---|
| CLOCK_50 | M9 | 50MHz入力 |
| KEY0_N | U7 | KEY0、押すとLow |
| LEDR0 | AA2 | Highで点灯 |

I/O規格は3.3-V LVTTL。SDCは20ns周期のクロックを定義し、非同期ボタンから
reset同期FFへの経路と、外部同期受信回路のないLED出力だけをタイミング対象外にする。
Quartus Lite 20.1でFit/STA成功、setup/holdともfully constrainedを確認済み。

## シミュレーション

リポジトリ直下で、Docker Desktopを起動して実行:

```bash
bash tools/test-de0cv-blink.sh
```

Verilator 5.046で`BLINK-TEST-PASS`を確認済み（M1、2026-11-09）。
実際の25,000,000カウントで反転・1秒周期を確認し、点灯中の非同期reset、
reset解除2クロック、パラメータ1と3の境界も検査する。
75,000,010クロックを回すため、このM1で実行に約1分かかった。
ログは `build/test/blink/{build,test}.log`。

## 合成

M1での環境構築は[実行記録](QUARTUS_M1_SETUP.md)を参照。公式の本体とCyclone V
パッケージをダウンロードして、Docker Desktop起動後に実行:

```bash
bash tools/setup-quartus.sh
bash tools/build-de0cv-blink-docker.sh
```

既存のLinux Quartus環境では:

```bash
QUARTUS_SH=/path/to/quartus/bin/quartus_sh bash tools/build-de0cv-blink.sh
```

プロジェクトを `build/fpga/de0-cv-blink/` へコピーしてビルドするため、
ソースディレクトリにQuartusの生成物を残さない。
出力先は `build/fpga/de0-cv-blink/quartus/output_files/de0_cv_blink.{sof,rbf}`。
SOFからRBFへの変換もビルドスクリプト内で行う。
ツールの実行ホストは別途必要であり、macOSでLinux実行ファイルを直接実行できない。

## 実機

M1上の書込みツールは、Homebrewを使わずローカルに準備できる:

```bash
bash tools/setup-de0cv-programmer.sh
local/fpga-tools/bin/openFPGALoader --detect -c usb-blaster
```

openFPGALoader v1.2.0をソースからビルドする。依存ライブラリとツールは
`local/`、生成物とパッケージ一覧は`build/`内に置く。
2026-11-09にM1と実機USB-Blasterで3回連続、IDCODE `0x02b050dd`
（Cyclone V A4）を読み取れた。最初の読出しはタイムアウトしたため、
USB認識だけをもってJTAG成功とはしない。その後、下記のSRAM書込みも成功した。

USB-Blaster経由でデバイス型番を確認後、上記のRBFを揮発性構成へ書き込む。
合成が完了したらリポジトリ直下で実行:

```bash
bash tools/program-de0cv-blink.sh
```

スクリプトはRBFの存在とA4のIDCODEを確認し、明示的に`--write-sram`で書き込む。
Flashへの書込みはこの手順の対象外。書込み後にKEY0を一度押して離し、
LEDR0が0.5秒間隔で点灯・消灯することを目視確認する。
シミュレーションPASSは実機点灯やFit/STA成功を意味しない。

## M1実機確認済み（2026-11-09）

Quartus Full Compilation成功、19 ALMs / 28 registers。50MHzで最小setup slack
15.813ns、hold slack 0.191ns、全4コーナーでTNS=0。SRAM書込みは100% / Done / exit 0。
ユーザーが実機LEDR0の点滅を確認した。LinuxやUARTの実機確認とは別の到達点。

警告4件: Quartusが`async_reg`属性を認識しない2件、LiteのLogicLockライセンス案内、
LEDR0のdrive strength/slew rate未指定。実際のFitでは2段同期チェーン1本を検出し、
LED出力は既定16mA/slew=1。3ピンの位置と3.3-V LVTTL割当てをレポートで確認した。
MTBF数値は未算出。ログは`build/logs/de0cv-blink-*`に保存する。
