# Project Task Status

この文書は、現在どこまで実装・確認できていて、次に何をやるべきかを機能ごとに見るための進捗表です。

関連文書:

- `Docs/ROADMAP.md`: 何をどの順番で進めるか
- `Docs/TEST_STATUS.md`: 実際に走らせたテスト結果
- `Docs/S-modetest.md`: Supervisor-mode 検証チェックリスト
- `Docs/DMA.md`: DMA 実装メモ

## 現在地

短期目標は、Linuxを直接起動する前に、RISC-Vのprivilege / trap / SBI / U-mode / MMUを小さいテストで固めることです。

現在はここです。

```text
M-mode trap
  -> S-mode transition
  -> S-mode trap
  -> minimal SBI putchar/getchar
  -> SBI set_timer
  -> timer / interrupt
  -> PMP
  -> U-mode transition
  -> U-mode syscall
  -> Sv39
  -> Linux-oriented platform
```

`minimal SBI putchar/getchar` と `SBI set_timer` の最小経路まで到達済みです。次は timer interrupt をS-modeへ通知する経路と、PMPを固めるのが自然です。

## 優先順位

| Priority | Area | Why |
|---:|---|---|
| 1 | SBI timer入口 | S-mode OSからM-mode firmwareへtimer設定を依頼するLinux/OpenSBI方向の基礎 |
| 2 | timer interrupt | OS scheduler / Linux bring-upに必要。SBI `set_timer` の最小経路は確認済み |
| 3 | PMP / access control | S-modeがRAM/MMIOへ安全にアクセスする前提。firmware保護にも必要 |
| 4 | U-mode transition | 本来のsyscall経路を作る前提 |
| 5 | U-mode syscall | `U-mode app -> S-mode OS` の本来のsyscall確認 |
| 6 | Sv39 MMU | Linux必須だが、trap/privilege後に進める方が安全 |
| 7 | Linux-oriented devices | UART / PLIC / DTBなどLinux bootに必要 |

## 機能別ステータス

| Area | Status | 確認済みテスト | 次にやること |
|---|---|---|---|
| RV64基本実行 | Partial | `make test-os2-min`, `make test-rv64um`, `make test-rv64ua` | `rv64ui-p-ma_data` など既知failを調査 |
| debug MMIO output | Pass | `make test-output`, `make test-os2-min` | 標準UART互換デバイスへ寄せる |
| debug MMIO input | Pass / bring-up用 | `make test-input INPUT_TEXT=A`, `make test-os2-min-input INPUT_TEXT=Z` | 標準UART互換デバイスへ寄せる |
| DMA | Pass / experimental | `make test-dma` | interrupt連携、仕様整理、バスプロトコル整理 |
| M-mode trap | Pass / basic | `make test-mswi`, `make test-mtime` | illegal instruction / fault時の `mtval` とflushを確認 |
| S-mode transition | Pass | `make test-os2-min-smode` | S-modeからM CSRアクセス時のillegal instruction確認 |
| S-mode trap | Pass / basic | `make test-os2-min-strap` | illegal instruction, ebreak, fault, `stval` を追加 |
| S-mode ecall delegation | Pass | `make test-os2-min-strap`, `make test-os2-min-sbi` | `medeleg[9]=0/1` の自動チェックを強める |
| Minimal SBI putchar | Pass | `make test-os2-min-sbi` | timer系SBIと同じdispatcherへ統合し続ける |
| SBI getchar | Pass | `make test-os2-min-sbi-input INPUT_TEXT=Z` | 将来のUART inputへ差し替えられる形を保つ |
| SBI timer | Pass / minimal | `make test-os2-min-sbi-timer` | S-mode timer interruptとして通知する経路を追加 |
| U-mode transition | Not started | none | `sstatus.SPP=U`, `sepc=user_entry`, `sret` |
| U-mode syscall | Not started | none | `medeleg[8]=1`, `U-mode ecall -> S-mode trap` |
| PMP | Not started | none | RAM/MMIO許可、firmware領域保護 |
| Sv39 | Not started | none | Bareからidentity mappingへ |
| Linux platform | Not started | none | UART, PLIC, DTB, OpenSBI/Linux image |

## テスト一覧

### Custom Tests

| Target | Status | 見ているもの |
|---|---|---|
| `make test-output` | Pass | debug MMIO output |
| `make test-input INPUT_TEXT=A` | Pass | debug MMIO input |
| `make test-dma` | Pass | DMA register設定とRAM-to-RAM copy |
| `make test-mswi` | Pass | machine software interrupt |
| `make test-mtime` | Pass | machine timer interrupt |
| `make test-os2-min` | Pass | OS2_min基本起動 |
| `make test-os2-min-input INPUT_TEXT=Z` | Pass | OS2_min input path |
| `make test-os2-min-smode` | Pass | M-modeからS-modeへ遷移 |
| `make test-os2-min-strap` | Pass | `medeleg[9]=1`, S-mode ecallがS-mode `stvec` へ入る |
| `make test-os2-min-sbi` | Pass | `medeleg[9]=0`, S-mode ecallがM-mode SBI handlerへ入る |
| `make test-os2-min-sbi-input INPUT_TEXT=Z` | Pass | SBI経由のdebug MMIO input |
| `make test-os2-min-sbi-timer` | Pass | SBI TIME `set_timer` と machine timer interrupt |

### riscv-tests Summary

詳細は `Docs/TEST_STATUS.md` を参照します。

| Suite | Current |
|---|---|
| `rv32ui-p` | Pass |
| `rv32um-p` / `rv64um-p` | Pass |
| `rv32ua-p` / `rv64ua-p` | Pass |
| `rv32uc-p` / `rv64uc-p` | Pass |
| `rv64ui-p` | Partial |
| `rv64mi-p` | Partial, 14 / 17 |
| `rv64si-p` | Partial |
| F/D/Zb/Zfh系 | Not claimed |

## 次の実装候補

### Option A: SBI timer入口

目的:

- 今の `SBI_EXT_TIME` / `SBI_FUNC_TIME_SET_TIMER` stubを実動作にする
- S-modeからM-mode firmwareへtimer設定を依頼できるようにする

作業:

- M-mode側でACLINT/mtimecmpへ書く関数を用意する
- `firmware.c` の `SBI_EXT_TIME` handlerを実装する
- S-mode側から `sbi_set_timer()` を呼ぶ
- timer interruptをM-modeまたはS-modeで確認する

完了条件:

- `make test-os2-min-sbi` が引き続きPass
- `make test-os2-min-sbi-input INPUT_TEXT=Z` が引き続きPass
- `make test-os2-min-sbi-timer` を追加してPass

### Option B: timer / interrupt

目的:

- S-mode OSがtimerを使える前提を作る
- SBI `set_timer` 相当の入口を作る

作業:

- M-mode側でACLINT/mtimecmpを操作する
- S-mode側からSBI `set_timer` を呼ぶ
- `mideleg` / `mie` / `sie` / `sstatus.SIE` の関係を確認する
- supervisor timer interruptがS-modeへ届くことを確認する

完了条件:

- S-mode handlerでtimer interruptを受ける
- `scause` がinterrupt bit付きのtimer causeになる
- `sret` で元のS-mode処理へ戻る

### Option C: PMP / access control

目的:

- S-modeから使うRAM/MMIOを許可し、M-mode firmware領域を守る

作業:

- RAMをS/U-modeからread/write/execute可能にする
- debug MMIOまたは将来UARTをS-modeから使えるようにする
- firmware領域をS-modeから書けないようにする
- 禁止アクセスでtrapすることを確認する

完了条件:

- 許可領域アクセスは成功
- 禁止領域アクセスは期待したfaultになる

### Option D: U-mode transition

目的:

- 本来のsyscallを作る準備

作業:

- U-mode用entryを用意
- U-mode stackを用意
- `sstatus.SPP=U`
- `sepc=user_entry`
- `sret`

完了条件:

- U-mode codeが1文字出力、またはS-modeへ戻る合図を出せる
- U-modeからS/M CSRアクセスでtrapする

### Option E: U-mode syscall

目的:

- 本来の `syscall = U-mode -> S-mode` を確認する

作業:

- `medeleg[8]=1`
- S-mode `stvec` を設定
- U-mode appが `ecall`
- S-mode handlerが `a7/a0-a5` を読む

完了条件:

- `U-mode ecall -> S-mode trap -> sepc += 4 -> sret` で復帰
- `SYS_putchar`, `SYS_exit` が動く

## 判断メモ

- `medeleg[9]=1` のS-mode self-trapは検証には有用だが、SBI用途では使わない
- SBI用途では `medeleg[9]=0` として、S-mode `ecall` をM-modeへ上げる
- 本来のOS syscallは `medeleg[8]=1` として、U-mode `ecall` をS-modeへ上げる
- Linuxへ行く前に、SBI / timer / PMP / U-mode / Sv39 を小さいテストで潰す
