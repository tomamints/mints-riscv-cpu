# Project Task Status

この文書は、現在どこまで実装・確認できていて、次に何をやるべきかを機能ごとに見るための進捗表です。

関連文書:

- `Docs/ROADMAP.md`: 何をどの順番で進めるか
- `Docs/TEST_STATUS.md`: 実際に走らせたテスト結果
- `Docs/S-modetest.md`: Supervisor-mode 検証チェックリスト
- `Docs/DMA.md`: DMA 実装メモ
- `Docs/RVA23_CHECKLIST.md`: RVA23方向の棚卸し

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

`minimal SBI putchar/getchar`、`SBI set_timer`、`MTIP -> M-mode handler -> STIP -> S-mode stvec`、periodic timer、PMP data access allow-all、PMP禁止TOR領域でのS-mode load/store/fetch access fault、禁止storeのRAM副作用抑止、U-mode transition、U-mode ecallの最小確認、Sv39 data-side identity mapping、SUM/MXR基本permissionまで到達済みです。Linux起動を優先するため、次は命令fetch側Sv39とpage fault確認へ進みます。

重要な前提として、ACLINTのtimer比較結果は `aclint.mtip -> mip.MTIP` に接続されています。`mideleg` だけでは `MTIP` は `STIP` に変換されないため、現在は M-mode timer handler が受けたMTIPをS-mode向けSTIPとして注入する経路を追加しています。将来的にはSstc実装も候補です。

## 優先順位

| Priority | Area | Why |
|---:|---|---|
| 1 | instruction fetch側Sv39 | Linux起動には命令fetchもVA->PA変換が必要 |
| 2 | Sv39 page fault追加 | store/fetch page fault、instruction page faultを確認する |
| 3 | Sv39補完 | PTWメモリエラー方針、MPRV/effective privilege、将来TLB用の`sfence.vma`整理 |
| 4 | Linux-oriented UART/DTB | early consoleとplatform記述に必要 |
| 5 | Linux-oriented devices | UART / PLIC / DTBなどLinux bootに必要 |

## 機能別ステータス

| Area | Status | 確認済みテスト | 次にやること |
|---|---|---|---|
| RV64基本実行 | Partial | `make test-os2-min`, `make test-rv64um`, `make test-rv64ua` | `rv64ui-p-ma_data` など既知failを調査 |
| debug MMIO output | Pass | `make test-output`, `make test-os2-min` | 標準UART互換デバイスへ寄せる |
| debug MMIO input | Pass / bring-up用 | `make test-input INPUT_TEXT=A`, `make test-os2-min-input INPUT_TEXT=Z` | 標準UART互換デバイスへ寄せる |
| DMA | Pass / experimental | `make test-dma` | interrupt連携、仕様整理、バスプロトコル整理 |
| M-mode trap | Pass / basic | `make test-mswi`, `make test-mtime` | illegal instruction / fault時の `mtval` とflushを確認 |
| S-mode transition | Pass | `make test-os2-min` | S-modeからM CSRアクセス時のillegal instruction確認 |
| S-mode trap | Pass / basic | `make test-os2-min-strap` | illegal instruction, ebreak, fault, `stval` を追加 |
| S-mode ecall delegation | Pass | `make test-os2-min-strap`, `make test-os2-min` | `medeleg[9]=0/1` の自動チェックを強める |
| Minimal SBI putchar | Pass | `make test-os2-min` | timer系SBIと同じdispatcherへ統合し続ける |
| SBI getchar | Pass | `make test-os2-min-input INPUT_TEXT=Z` | 将来のUART inputへ差し替えられる形を保つ |
| SBI timer | Pass / periodic basic | `make test-os2-min` | timer間隔やdeadline再設定方針を整理 |
| S-mode timer interrupt | Pass / periodic basic | `make test-os2-min` | interrupt中のSIE/SPIEを追加確認 |
| U-mode transition | Pass / minimal | `OS2_MIN_USER` | Linux最短では深追いしない。必要になったらU-mode stack分離やCSR faultを追加 |
| U-mode syscall | Pass / minimal | `OS2_MIN_USER` | Linux最短では深追いしない。自作OS検証時にsyscall番号、exit/putchar、trap frameを整理 |
| PMP | Pass / load/store/fetch fault basic | `make test-os2-min`, `make test-os2-min-input INPUT_TEXT=Z`, `make test-os2-min-strap`, `OS2_MIN_PMP` | MMIO副作用抑止確認、部分重複テスト、firmware領域保護 |
| Sv39 | Pass / data-side minimal | `make test-os2-min-sv39` | `sv39_ptw.sv` をdata-sideから利用中。identity load/store、2MiB L1 / 1GiB L2 superpage、unmapped fault、SUM、MXR、A=0 load fault、D=0 store faultは確認済み。`Sv39Fault` で内部fault理由も追跡可能。PTW PTE read errorはaccess fault方針。次は命令fetch側Sv39、store/fetch page fault、PTW error発生源、TLB |
| Linux platform | Not started | none | UART, PLIC, DTB, OpenSBI/Linux image |

## テスト一覧

Linux起動を大目標にするため、U-mode syscallは最小確認済みで一旦区切ります。Sv39はdata-side最小identity mapping、2MiB L1 / 1GiB L2 superpage、SUM/MXRまで確認済みで、PTWは `sv39_ptw.sv` に分離済みです。次の主作業は命令fetch側Sv39です。

### Custom Tests

| Target | Status | 見ているもの |
|---|---|---|
| `make test-output` | Pass | debug MMIO output |
| `make test-input INPUT_TEXT=A` | Pass | debug MMIO input |
| `make test-dma` | Pass | DMA register設定とRAM-to-RAM copy |
| `make test-mswi` | Pass | machine software interrupt |
| `make test-mtime` | Pass | machine timer interrupt |
| `make test-os2-min` | Pass | S-mode遷移、SBI putchar、SBI set_timer、MTIPからSTIP注入、S-mode timer interrupt、periodic timer 3回 |
| `make test-os2-min-input INPUT_TEXT=Z` | Pass | SBI経由のdebug MMIO input |
| `make test-os2-min-strap` | Pass | `medeleg[9]=1`, S-mode ecallがS-mode `stvec` へ入る |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=300000` | Pass | PMP禁止TOR領域へのS-mode load/store/fetchで `scause=5/7/1`, `stval=fault address`。禁止storeでRAM値が変化しないこと、fetchがRではなくXを見ること、32-bit命令後半2byteのX禁止も確認 |
| `make test-os2-min-sv39` | Pass | S-modeで`satp.MODE=8`を設定し、4KiB PTEの3-level page walkでdata load/storeをidentity mapping。2MiB L1 / 1GiB L2 superpage、未map load、SUM=0/1、MXR=0/1を確認 |

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

### Option A: PMP / Access Control

目的:

- S-mode / U-modeから使えるRAM/MMIO範囲を定義する
- M-mode firmware領域をS-modeから保護する
- PMP fault時に副作用のあるmemory/MMIO requestを出さない

作業:

- PMP allow-all構成を作り、まず既存S-modeテストが壊れないことを確認する
- PMP禁止TOR領域へのS-mode load/storeでaccess faultになることを確認する
- 禁止storeでRAM値が変化しないことを確認する
- fault時にMMIO requestが発行されないことを確認する
- instruction fetchにもPMP X permissionを適用する
- RAM / debug MMIO / ACLINT のアクセス許可範囲を明文化する
- firmware text/dataをS-modeからアクセス禁止にする
- 部分重複、MMIO許可/禁止などのtrapを追加テストする

完了条件:

- `make test-os2-min` が引き続きPass
- 許可したRAM/MMIO accessが通る
- 禁止したfirmware領域accessがfaultになる
- 禁止fetchがinstruction access faultになる
- fetchがR permissionではなくX permissionを見ることを確認する
- 32-bit命令の後半2byteがPMP境界をまたぐfetch faultを確認する

### Option B: timer / interrupt

目的:

- S-mode OSが周期timerを使える前提を作る

作業:

- S-mode timer handler内で次回timerを再設定する
- periodic timerとして複数回割り込みを受ける
- interrupt中の `SIE/SPIE` と `sepc` 保存を確認する

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
- 現在のSv39はdata-sideのみ。命令fetch側はまだ物理PCのままなので、Linux起動前に必ず対応する
