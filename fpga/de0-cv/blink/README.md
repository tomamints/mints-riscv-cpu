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
QuartusでのFit/STAは未実施であり、制約が受理されることも合成時に確認する。

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

Quartus Lite 20.1とCyclone V device supportを用意して実行:

```bash
QUARTUS_SH=/path/to/quartus/bin/quartus_sh bash tools/build-de0cv-blink.sh
```

プロジェクトを `build/fpga/de0-cv-blink/` へコピーしてビルドするため、
ソースディレクトリにQuartusの生成物を残さない。
出力先は `build/fpga/de0-cv-blink/quartus/output_files/de0_cv_blink.sof`。
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
USB認識だけをもってJTAG成功とはしない。以後の確認はすべて読出しのみ。

USB-Blaster経由でデバイス型番を確認後、上記のSOFを揮発性構成へ書き込む。
合成が完了したらリポジトリ直下で実行:

```bash
bash tools/program-de0cv-blink.sh
```

スクリプトはSOFの存在とA4のIDCODEを確認し、明示的に`--write-sram`で書き込む。
Flashへの書込みはこの手順の対象外。書込み後にKEY0を一度押して離し、
LEDR0が0.5秒間隔で点灯・消灯することを目視確認する。
シミュレーションPASSは実機点灯やFit/STA成功を意味しない。
