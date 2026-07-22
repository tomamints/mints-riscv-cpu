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

注意点:

- 本来の syscall は U-mode から S-mode へ入る `ecall`
- SBI は S-mode から M-mode firmware へ入る `ecall`
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
- SBI `set_timer` 相当の経路を作る
- Supervisor timer interruptをS-mode trap handlerで受ける

作業:

- M-mode firmware側でACLINT/mtimecmpを操作する
- S-mode側からSBI `set_timer` を呼ぶ
- `mideleg` / `mie` / `sie` / `sstatus.SIE` を設定する
- timer interrupt発生時に `stvec` へ入ることを確認する

完了条件:

- S-mode handlerでtimer interruptを受ける
- `scause` がinterrupt bit付きのtimer causeになる
- `sepc` が割り込まれた位置を保持する
- `sret` で元のS-mode処理へ戻る

## Phase 6: PMP / Access Control

目的:

- S-mode / U-modeから使えるRAM/MMIOを定義する
- M-mode firmware領域をS-modeから保護する

作業:

- RAMをS/U-modeへ許可
- debug MMIOまたは将来UARTを許可
- firmware領域をS-modeから書き換え不可にする
- 許可/禁止アクセスのtrapを確認する

完了条件:

- 許可領域のread/write/executeが成功する
- 禁止領域アクセスがfaultになる

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

MMU なしでも U-mode は意味があります。メモリ保護は弱いですが、privilege 分離と trap 経路の確認には使えます。

## Phase 8: U-mode Syscall

目的:

- 本来の意味での syscall を作る

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

## Phase 9: Linux-oriented Devices

目的:

- Linux の既存 driver が使える形へ platform を寄せる

優先度が高いもの:

- NS16550A 互換 UART
- ACLINT/CLINT compatible timer/software interrupt
- PLIC compatible external interrupt controller

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

## Phase 10: Sv39 MMU

目的:

- Linux が必要とする仮想記憶を CPU 側へ実装する

必要な要素:

- `satp`
- Sv39 3-level page table walk
- ITLB / DTLB または同等の変換 cache
- instruction page fault
- load page fault
- store/AMO page fault
- PTE permission
- U/S permission
- `SUM`
- `MXR`
- A/D bit policy
- `sfence.vma`
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

## Phase 11: Device Tree

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

## Phase 12: Linux Image + Initramfs

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

1. 最小SBIを `sbi.c` / `platform.c` / `firmware.c` へ整理する
2. SBI `getchar` と `set_timer` の入口を追加する
3. timer / interrupt をS-modeで受ける
4. PMPでRAM/MMIOとfirmware領域のアクセス制御を確認する
5. U-modeへ落として U-mode `ecall` をS-modeで受ける
