# DMA ドキュメント

## 目的

本 DMA は、RISC-V コアがメモリコピーに費やす命令実行を削減するための独自 MMIO peripheral です。

CPU は MMIO register 経由で転送元、転送先、転送長を設定し、`CTRL.start` で DMA を開始します。DMA は RAM master として RAM へアクセスし、8 byte 単位で RAM 間コピーを行います。

この DMA は教材「Verylで作るCPU」由来ではなく、このリポジトリで追加している実験的な機能です。

## 現在の対応状況

実装済み:

- MMIO slave としての register read/write
- RAM master としての read/write 転送
- 8 byte 単位の RAM 間コピー
- `busy`, `done`, `err` status
- 8 byte alignment check
- `LEN == 0` の即時完了
- CPU 優先の RAM arbitration

未実装 / 制限:

- DMA interrupt 出力
- byte / halfword / word 単位のコピー
- RAM 範囲外アドレスの error check
- 複数 channel
- scatter-gather
- DMA 専用の自動テスト

## 接続

### MMIO slave

CPU から DMA register へアクセスする bus です。

入力:

- `valid`
- `addr`
- `wen`
- `wdata`
- `wmask`

出力:

- `ready`
- `rvalid`
- `rdata`

`mmio_controller` は `MMAP_DMA_BEGIN` から `MMAP_DMA_END` のアクセスを DMA に decode し、DMA には `addr - MMAP_DMA_BEGIN` の offset address を渡します。

### RAM master

DMA が RAM を read/write するための master bus です。

`top.sv` では、CPU 側 RAM access と DMA 側 RAM access が `ram_arbiter_cpu_prio` に接続されています。現在の arbiter は CPU 優先です。

### Clock / Reset

入力:

- `clk`
- `rst`

`rst` は active-low reset です。

## Address Map

現在の実装は `src/eei.sv` の定義を正とします。

```systemverilog
localparam Addr MMAP_DMA_BEGIN  = Addr'('h3000_0000);
localparam Addr MMAP_DMA_CTRL   = Addr'('h00);
localparam Addr MMAP_DMA_STATUS = Addr'('h08);
localparam Addr MMAP_DMA_SRC    = Addr'('h10);
localparam Addr MMAP_DMA_DST    = Addr'('h18);
localparam Addr MMAP_DMA_LEN    = Addr'('h20);
localparam Addr MMAP_DMA_END    = MMAP_DMA_BEGIN + Addr'('h0FFF);
```

| Register | Offset | Access | Description |
|---|---:|---|---|
| `CTRL` | `0x00` | RW | start / clear_done / irq_en |
| `STATUS` | `0x08` | RO | busy / done / err |
| `SRC` | `0x10` | RW | 転送元 RAM address |
| `DST` | `0x18` | RW | 転送先 RAM address |
| `LEN` | `0x20` | RW | 転送 byte 数 |

## Register Specification

### CTRL: offset 0x00

| Bit | Name | Access | Description |
|---:|---|---|---|
| 0 | `start` | W | `1` を書くと DMA を開始する |
| 1 | `clear_done` | W | `done` と `err` を clear する |
| 2 | `irq_en` | RW | 現在は保持のみ。interrupt 出力は未実装 |
| 63:3 | reserved | RO | `0` を返す |

補足:

- `start` は write pulse として扱う。
- DMA 動作中の `start` は無視する。
- `clear_done` は write pulse として扱い、read 時は `0` を返す。
- `irq_en` は register として保持されるが、現在は DMA 外部へ `irq` output を出していない。

### STATUS: offset 0x08

| Bit | Name | Access | Description |
|---:|---|---|---|
| 0 | `busy` | RO | 転送中は `1` |
| 1 | `done` | RO | 転送完了で `1` |
| 2 | `err` | RO | error 発生で `1` |
| 63:3 | reserved | RO | `0` を返す |

`done` と `err` は `CTRL.clear_done` により clear されます。

### SRC: offset 0x10

転送元 RAM address を保持します。

- CPU は RAM の絶対 address を書く想定です。
- DMA 開始時に `SRC - MMAP_RAM_BEGIN` を RAM offset として使用します。
- DMA 動作中の write は無視します。
- 8 byte aligned である必要があります。

### DST: offset 0x18

転送先 RAM address を保持します。

- CPU は RAM の絶対 address を書く想定です。
- DMA 開始時に `DST - MMAP_RAM_BEGIN` を RAM offset として使用します。
- DMA 動作中の write は無視します。
- 8 byte aligned である必要があります。

### LEN: offset 0x20

転送 byte 数を保持します。

- DMA 動作中の write は無視します。
- 8 byte aligned である必要があります。
- `LEN == 0` の場合、RAM access を行わず `done` になります。

## 動作

DMA 開始時に `SRC`, `DST`, `LEN` を内部状態へ取り込みます。その後、以下の単位動作を `LEN / 8` 回繰り返します。

1. `cur_src` から 8 byte read request を出す
2. RAM の `rvalid` を待つ
3. 読み出した 8 byte を `cur_dst` へ write request する
4. `cur_src += 8`, `cur_dst += 8`, `rem -= 8`

write は RAM bus の `ready` で request が受け付けられた時点で完了扱いにします。

## FSM

現在の実装状態:

- `IDLE`
- `READ_REQ`
- `READ_WAIT`
- `WRITE_REQ`
- `DONE`
- `ERR`

主な遷移:

- `IDLE -> READ_REQ`: `CTRL.start == 1` かつ alignment OK かつ `LEN != 0`
- `IDLE -> DONE`: `CTRL.start == 1` かつ `LEN == 0`
- `IDLE -> ERR`: `SRC`, `DST`, `LEN` のいずれかが 8 byte misaligned
- `READ_REQ -> READ_WAIT`: RAM read request が `ready`
- `READ_WAIT -> WRITE_REQ`: RAM read response が `rvalid`
- `WRITE_REQ -> READ_REQ`: まだ残り byte がある
- `WRITE_REQ -> DONE`: 最後の 8 byte write request が `ready`
- `DONE -> IDLE`: `done` を保持したまま idle へ戻る
- `ERR -> IDLE`: `err` を保持したまま idle へ戻る

## Error Handling

現在 `err` になる条件:

- `SRC` が 8 byte aligned ではない
- `DST` が 8 byte aligned ではない
- `LEN` が 8 byte aligned ではない

現在 `err` にならない条件:

- `SRC` / `DST` が RAM 範囲外
- RAM access の bus error

現状の memory bus には bus error response がないため、RAM access 失敗の検出は未実装です。

## Software Sequence

例:

```text
write DMA_SRC, source_address
write DMA_DST, destination_address
write DMA_LEN, byte_length
write DMA_CTRL, start=1

poll DMA_STATUS until done=1 or err=1
write DMA_CTRL, clear_done=1
```

`source_address`, `destination_address`, `byte_length` はすべて 8 byte aligned にしてください。

## 今後の候補

- RAM 範囲 check
- `irq` output と interrupt controller への接続
- byte mask を使った非 8 byte aligned / 非 8 byte 長転送
- DMA 専用 test program
- `Docs/DMA.md` と実装の register map を自動検証するテスト
