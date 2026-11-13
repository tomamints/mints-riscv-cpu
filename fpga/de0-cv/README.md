# DE0-CV board support

Terasic DE0-CV（Cyclone V `5CEBA4F23C7N`）向けの回路とツール。

| 内容 | 使用方法 |
|---|---|
| **CPU＋Linux＋BusyBox（実機）** | [構成・配線・ビルド・起動・確認方法](soc/README.md) |
| LED点滅 | [blink/README.md](blink/README.md) |
| UARTエコー | [uart_echo/README.md](uart_echo/README.md) |
| 同期RAMの合成プローブ | `mem_probe/`、`tools/build-mem-probe-docker.sh` |
| SDRAMコントローラと単体実機テスト | [sdram/README.md](sdram/README.md) |

`rtl/uart_phy.sv` は8N1送受信器とbaud enable生成器をまとめます。
`CLK_HZ` のクロック上で動作し、baudは `REF_HZ / (16 * divisor)` です。
RX入力は2段同期し、フレーミングエラーとBREAKを通知します。

UART PHYの単体テスト:

```sh
bash tools/test-de0cv-uart.sh
```

テスト・合成の出力はGit管理外の `build/` に保存します。
ボード書き込みツールはSRAMへの一時設定を使用します。
