# Roadmap

この文書は、現在の SystemVerilog RISC-V CPU と `core/test/os2_min` を、将来的に Linux 起動や RVA23 方向へ近づけるための作業順序を整理したものです。

## Current Position

現在の到達点:

- RV64 kernel として `core/test/os2_min` が起動する
- debug MMIO `0x40000000` 経由で `printf` / `getchar` が動く
- trap entry で汎用レジスタを `struct trap_frame` に保存できる
- M-mode から `mstatus.MPP=S` / `mepc=supervisor_main` / `mret` で S-mode へ遷移できる
- S-mode `ecall` が `stvec` へ入り、`sepc += 4` 後に `sret` で復帰できる
- S-mode `ecall` が M-mode の SBI dispatcher へ入り、debug console putchar/getchar が動く
- SBI TIME `set_timer` が M-mode firmware経由で ACLINT `mtimecmp` を設定し、machine timer interrupt を発生できる
- M-mode timer handlerがSTIPを注入し、S-mode `stvec` で supervisor timer interrupt を受けられる
- `satp.MODE=8` を保持し、data-sideのSv39 3-level page table walkで4KiB identity mappingを確認できる

注意点:

- 本来の syscall は U-mode から S-mode へ入る `ecall`
- SBI は S-mode から M-mode firmware へ入る `ecall`
- `mideleg` は既に存在するpending bitの配送先を変える機構であり、`MTIP` を `STIP` に変換する機構ではない。現在はM-mode firmwareが明示的にSTIPを注入する
- 今の debug MMIO は Linux 標準デバイスではなく、シミュレータ用の独自 console

## Target Direction

長期目標は、RV64 kernel として OS2_min を育てながら、CPU 側を Linux / RVA23 方向へ寄せることです。

短期的には Linux を直接起動しようとせず、以下を自作テストで固めます。

```text
M-mode trap
  -> S-mode transition
  -> S-mode trap
  -> minimal SBI
  -> timer / interrupt
  -> PMP
  -> U-mode transition
  -> U-mode syscall
  -> Sv39 MMU
  -> standard-ish devices
  -> DTB
  -> Linux Image + initramfs
```

## Phase 1: M-mode Trap Foundation

目的:

- M-mode trap の precise な動作を確認する
- 後続命令が誤って commit されないことを確認する
- trap 後に元の処理へ正しく戻れることを確認する

確認済み:

- `ecall`
- `mtvec`
- `mepc`
- `mcause`
- `mret`
- 汎用レジスタ保存と復元

次に追加したいテスト:

- illegal instruction
- load/store fault
- timer interrupt
- software interrupt
- `mtval` の値
- trap 時の pipeline flush

## Phase 2: S-mode Transition

目的:

- M-mode boot code から S-mode kernel へ入る

確認済み:

- `mstatus.MPP=S`
- `mepc=supervisor_main`
- `mret`
- S-mode で `sstatus` を読める

確認済み:

- `make test-os2-min-strap` で S-mode `ecall` が `stvec` へ入る
- handler 内で `sepc += 4` を書ける
- `sret` 後に同じ `ecall` へ戻らず、次のS-mode処理へ復帰する

次に確認すること:

- S-mode で M-mode 専用 CSR へ触ると illegal instruction になる
- S-mode から debug MMIO へアクセスできる
- PMP やアクセス制御を入れる場合、S-mode が必要な MMIO/RAM へアクセスできる

## Phase 3: S-mode Trap

目的:

- S-mode kernel の trap handler を作る
- `stvec` / `sepc` / `scause` / `stval` / `sstatus` / `sret` を検証する

必要な作業:

- S-mode 用 trap entry を追加
- S-mode 用 trap frame を使う
- `stvec` に S-mode trap entry を設定
- S-mode 内で `ecall` や illegal instruction を起こす
- handler で `sepc += 4` して `sret` で戻る

完了条件:

- S-mode `ecall` が trap へ入る
- `scause` が期待値になる
- `sepc` が trap 発生 PC になる
- `sret` で元のS-mode処理へ戻れる

## Phase 4: Minimal M-mode Firmware / SBI

目的:

- S-mode OS から M-mode firmware へ依頼する経路を作る

構造:

```text
M-mode firmware
  - mtvec
  - SBI handler
  - platform_putchar
  - platform_getchar
  - set_timer
  - start S-mode OS

S-mode OS2_min
  - stvec
  - syscall handler
  - SBI client
```

最初の SBI 範囲:

- console putchar
- console getchar
- set timer
- system reset

注意:

- SBI console は bring-up 用として扱う
- Linux の通常 console は、最終的には UART driver 経由に寄せる

## Phase 5: Timer / Interrupt

目的:

- S-mode OSがtimerを使えるようにする
- SBI `set_timer` でM-mode firmwareがtimerを設定する経路を作る
- Supervisor timer interruptをS-mode trap handlerで受ける

現在の前提:

- ACLINTの比較結果は `aclint.mtip -> mip.MTIP` に接続されている
- `mideleg` を設定しても `MTIP` が自動的に `STIP` へ変換されるわけではない
- M-mode firmwareがACLINT MMIO経由で `mip.STIP` をpendingにできる経路を追加済み

採用方針:

まずは方式A、つまり M-mode firmware が MTIP を受け、S-modeへ supervisor timer interrupt を注入する方式で進めます。この経路は `make test-os2-min` で、3回のperiodic timer再設定まで確認済みです。将来的には Sstc の `stimecmp` 実装も検討します。

```text
S-mode
  -> SBI set_timer(deadline)
M-mode firmware
  -> mtimecmp = deadline
time reached
  -> MTIP
  -> M-mode timer handler
  -> STIPをpendingにする
S-mode
  -> Supervisor Timer Interrupt
  -> stvec
```

確認済み:

- M-mode firmware側でACLINT `mtimecmp` を操作する
- S-mode側からSBI `set_timer` を呼ぶ
- MTIPをM-mode trap handlerで受ける
- M-mode handlerで `mtimecmp` を無効化または再設定する
- M-modeからSTIPをpendingにできるRTL経路を作る
- `mideleg.STI` / `sie.STIE` / `sstatus.SIE` を設定する
- supervisor timer interrupt発生時に `stvec` へ入ることを確認する
- S-mode timer handlerから元の処理へ戻って継続実行する
- timerを複数回再設定し、periodic timerとして確認する
- `sip.STIP` をS-mode handlerからclearする

次に追加すること:

- interrupt中の `sstatus.SIE/SPIE` の保存復元を明示確認する
- timer間隔やdeadline再設定方針を整理する

完了条件:

- S-mode handlerでtimer interruptを受ける
- `scause` がinterrupt bit付きのtimer causeになる
- `sepc` が割り込まれた位置を保持する
- `sret` で元のS-mode処理へ戻る
- timerを複数回再設定して受けられる

## Phase 6: PMP / Access Control

目的:

- S-mode / U-modeから使えるRAM/MMIOを定義する
- M-mode firmware領域をS-modeから保護する

作業:

- step 1: data load/storeに対するPMP checkを追加する
- step 1: PMP判定を `src/pmp_checker.sv` に分離し、core本体はallow/fault判定結果だけを見る
- step 1: M-modeはL=0相当としてPMP checkをバイパスする
- step 1: PMP NAPOT allow-allをM-mode bootで設定し、既存S-modeテストを維持する
- step 1: RAM全体をS/U-modeへ広く許可し、まず動作確認を優先する
- step 1: debug MMIOまたは将来UARTを必要範囲だけ許可する
- step 2: M-mode firmware text/dataをS/U-modeからアクセス禁止にする
- step 3: U-modeの本格的な分離はSv39ページテーブル側へ寄せる
- 許可/禁止アクセスのtrapを確認する

確認済み:

- `pmpcfg0`, `pmpaddr0`〜`pmpaddr3` のCSR read/write
- `pmpcfg0` は4エントリ分だけ保持し、Lビットは0相当
- data load/storeでPMP matchとR/W permissionを確認する
- `memunit.valid` は既存exceptionが無い命令だけdata bus accessを出す
- PMP entryはaccessの一部でも重なればmatch候補になり、番号の小さいentryを優先する
- 優先されたentryがaccess size全体を含まない場合はaccess faultにする
- `pmpaddr0=~0UL`, `pmpcfg0=NAPOT|R|W|X` のallow-allで既存S-modeテストがPass
- `OS2_MIN_PMP` で、entry1のTOR禁止領域にS-mode load/storeすると `scause=5/7`, `stval=fault address` でS-mode trapへ入る
- 禁止store後にM-mode SBIで保護wordを読み直し、RAM値が変化していないことを確認する
- instruction fetchにもPMP X permissionを適用し、`X=1/R=0/W=0`で実行成功、`R=1/W=1/X=0`で `scause=1`, `stval=fetch address` を確認する
- 32-bit命令の後半2byteがX禁止領域に入る場合も、issue段の命令長ベースPMP checkで `scause=1` になることを確認する

完了条件:

Step 1完了条件:

- 許可領域のload/storeが成功する
- 禁止領域のload/storeがaccess faultになる
- 禁止storeでRAM値が変化しない
- 禁止領域からのfetchがinstruction access faultになる

Phase 6全体の完了条件:

- RAM/MMIO/firmware領域のPMP方針を分ける
- fault時にMMIO requestが発行されないことを波形または専用MMIOテストで確認する
- 部分重複accessの優先順位を専用テストで確認する

## Phase 7: U-mode Transition

目的:

- S-mode kernel から U-mode program へ入る

作業:

- `sstatus.SPP=U`
- `sepc=user_entry`
- `sret`
- U-mode 用 stack を用意

確認すること:

- U-mode で通常命令が実行できる
- U-mode から S/M-mode CSR に触ると trap になる
- U-mode `ecall` が S-mode trap へ届く

現在:

- `OS2_MIN_USER` で `sstatus.SPP=U`, `sepc=user_entry`, `sret` によりU-mode entryへ入る
- U-mode `ecall` が `medeleg[8]` によりS-mode trapへ入り、`scause=8` になる
- 1回目のU-mode `ecall` は `a0=0x5678`, `sepc += 4`, `sret` でU-modeへ復帰する
- 2回目のU-mode `ecall` はexit syscallとしてS-mode handler内で成功終了する

MMU なしでも U-mode は意味があります。メモリ保護は弱いですが、privilege 分離と trap 経路の確認には使えます。

## Phase 8: U-mode Syscall

目的:

- 本来の意味での syscall を作る
- Linux起動を優先する場合は、ここを深追いせず最小確認で区切る

基本 ABI:

```text
a7 = syscall number
a0 = arg0 / return value
a1 = arg1
a2 = arg2
```

最初の syscall:

- `SYS_putchar`
- `SYS_getchar`
- `SYS_exit`

その後:

- `SYS_write`
- `SYS_read`
- `SYS_yield`

完成イメージ:

```text
U-mode application
  -> ecall
S-mode OS syscall handler
  -> SBI if needed
M-mode firmware
  -> hardware
```

現在は `OS2_MIN_USER` で、U-modeへ入り、U-mode `ecall` をS-modeで受け、1回目は戻り値を返してU-modeへ復帰し、2回目はexitとして処理する最小経路まで確認済みです。Linux起動を大目標にする場合、ここで一旦区切り、次はSv39へ進みます。

## Phase 9: Sv39 MMU

目的:

- Linuxに必須のS-mode仮想記憶を最小構成で動かす

最初に作る範囲:

- `satp` CSR
- `MODE=8` Sv39
- 3-level page table walk
- 4KiB pageのみ
- ASID無視
- TLBなし、または全flush扱い
- identity mapping
- R/W/X/U permission
- instruction/load/store page fault
- `sfence.vma` は全flushまたはno-op相当から開始

現在:

- `satp` CSRをread/writeできる
- `sv39_ptw.sv` に3-level page table walkerを分離し、data-side load/storeから利用している
- 4KiB PTEだけを3-level walkする
- 先頭2MiB RAMとdebug MMIO 1ページのidentity mappingでS-mode load/storeが成功する
- 未map addressのloadで `LOAD_PAGE_FAULT`, `stval=fault VA` を確認済み
- `SUM=0/1` によるS-modeからUページへのdata access制御を確認済み
- `MXR=0/1` によるexecute-onlyページのload制御を確認済み
- 非leaf PTEの予約bitとmisaligned superpageはpage faultにする
- 2MiB L1 superpage aliasのloadを確認済み
- 1GiB L2 superpageのPA合成はPTWに実装済み。ただし専用テストは未追加
- `sfence.vma` はTLBなしのためno-op命令として受ける

未対応:

- instruction fetch側のSv39
- store page fault / instruction page faultのSv39専用テスト
- L2 superpage専用テスト
- PTW中のPTE読み出しに対するbus/PMP error入力
- TLB / ASID
- A/D bitのhardware update
- permissionの厳密な仕様準拠

最初のテスト:

```text
VA 0x8000_0000
  -> Sv39 page table walk
PA 0x8000_0000
```

最初は仮想アドレスと物理アドレスを同じにして、既存S-modeコードがそのまま動くことを確認します。`make test-os2-min-sv39` ではdata-sideのload/store identity mapping、2MiB L1 superpage、未map load page fault、SUM/MXRの基本permissionまで確認済みです。次は命令fetch側からも `sv39_ptw.sv` を使えるようにします。

## Phase 10: Linux-oriented Devices

目的:

- Linux の既存 driver が使える形へ platform を寄せる

優先度が高いもの:

- NS16550A 互換 UART
- ACLINT/CLINT compatible timer/software interrupt
- PLIC compatible external interrupt controller

最初のLinux起動へ向けた分割:

- Phase 10A: NS16550A polling UART と ACLINT/SBI timer
- Phase 10B: PLIC、UART interrupt、その他device interrupt

UART:

- `THR` / `RBR`
- `LSR`
- `IER`
- `IIR`
- `LCR`
- `DLL` / `DLM`
- polling TX から開始してよい
- 最終的には interrupt 対応が必要

ACLINT/CLINT:

- `mtime`
- `mtimecmp`
- `mswi`
- S-mode OS からは SBI timer 経由で使う構成を基本にする

PLIC:

- priority
- pending
- enable
- threshold
- claim/complete
- DTB の interrupt number と RTL 実装を一致させる

## Phase 11: Sv39 Completeness

目的:

- identity mapping後にLinux向けの細部を詰める

必要な要素:

- ITLB / DTLB または同等の変換 cache
- superpage
- U/S permissionの詳細
- `SUM`
- `MXR`
- A/D bit policy
- canonical virtual address check
- ASID policy

最初の実装範囲:

- 4 KiB page
- single hart
- ASID は 0 のみ、または無視
- `sfence.vma` は全 flush
- A/D bit は hardware update か fault 方式のどちらかに決める

OS2_min で確認すること:

- VA to PA mapping
- read/write/execute permission
- unmapped page fault
- read-only page への write fault
- NX page からの fetch fault
- U/S permission fault
- non-canonical VA fault
- `stval` / `scause` / `sepc`

## Phase 12: Device Tree

目的:

- Linux に hardware description を渡す

Linux entry の基本:

```text
a0 = hart id
a1 = DTB physical address
satp = 0
```

最低限必要な node:

- `/cpus`
- `/memory`
- `/chosen`
- UART
- interrupt controller
- timer / ACLINT / CLINT
- PLIC

注意:

- DTB の address map と RTL の address map を一致させる
- RAM base/size、UART base、interrupt number、timebase-frequency をズラさない

## Phase 13: Linux Image + Initramfs

最初の Linux 構成:

- RV64
- single hart
- SMP off
- PCI off
- virtio off
- initramfs built-in
- UART console
- Sv39
- SBI timer
- PLIC

最初の到達点:

```text
firmware log
Linux earlycon
Linux boot log
initramfs /init
shell
```

## Near-term Next Steps

直近でやる順番:

1. instruction fetch側にもSv39変換を入れる
2. Sv39のstore page faultとinstruction page faultを確認する
3. L2 superpageテストとPTWメモリエラー方針を追加する
4. NS16550A polling UARTを追加する
5. 最小DTBを用意する
6. OpenSBIまたは独自SBI互換性を確認し、Linux early bootへ入る

U-mode syscall cleanup、PMP MMIO副作用、PMP部分重複テストは重要ですが、Linux起動を優先する場合はSv39後の補助タスクとして扱います。
