# Roadmap

この文書は、現在の **MiNTs-CPU** と `core/test/os2_min` を、将来的に Linux 起動や RVA23 方向へ近づけるための作業順序を整理したものです。

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
- `0x10000000` にNS16550A互換の最小UARTを置き、polling TXでVerilator標準出力へ文字を出せる
- OpenSBI v1.3.1 `FW_JUMP` が起動し、UART banner、ACLINT MSWI、ACLINT MTIMERを認識する
- OpenSBIからS-mode payloadへhandoffできる
- Linux 6.12.y `Image` を `0x80200000` に配置し、OpenSBIからLinuxへhandoffできる
- Linux 6.12.97のearlycon / normal console boot logが出る
- LinuxがSBI Base/Time/IPI/RFENCE、reserved memory、Sv39 virtual kernel memory layout、SLUB、RCU、`riscv-intc`、`riscv_clocksource`、`sched_clock`、PLIC、8250 UART、`/init` まで到達する
- BusyBox initramfsの `cmdloop-ttyS0` で `echo OK` が `read()` から戻り、`line=[echo OK]`, `OK`, 次の `MARK-B` まで進む

現在のLinux bring-up観測点:

- UART THRE interruptは、LinuxのIIR readでpendingをclearする
- `mip/sip.SEIP` はPLIC外部信号で決まり、CSR writeで内部にラッチしない
- `sret/mret` は `SPIE/MPIE` を仕様どおり復元する
- RTLでは `mtime` が毎CPUクロック増えるため、DTBの `timebase-frequency` はCPU clock想定の50MHzへ合わせる
- 次はtraceなしで `cmdloop-ttyS0` の複数回入力、procfs、tmpfs、通常shell化を確認する

注意点:

- 本来の syscall は U-mode から S-mode へ入る `ecall`
- SBI は S-mode から M-mode firmware へ入る `ecall`
- `mideleg` は既に存在するpending bitの配送先を変える機構であり、`MTIP` を `STIP` に変換する機構ではない。現在はM-mode firmwareが明示的にSTIPを注入する
- 今の debug MMIO は Linux 標準デバイスではなく、シミュレータ用の独自 console
- Linux向けconsoleは、debug MMIOではなくNS16550A互換UARTへ寄せる
- VerilatorではLinux bootが非常に遅い。`+TRACE_PIPE` はさらに遅くなるため、長時間確認では外す

## Development Policy After Linux Bring-up

Linuxが動き始めた後は、機能を思いつきで足すのではなく、次の方針で進めます。

```text
1. 性能ボトルネックを測れるようにする
2. 性能機能をCPU本体から分離し、差し替えやすくする
3. TLB/cache/predictorなどを小さい構成から追加する
```

目的は、変更前後で「なぜ速くなったか」「なぜ遅くなったか」「どこが壊れたか」を追える状態を保つことです。

### Performance Measurement First

TLBやI-cacheを入れる前に、最低限の性能カウンタを用意します。

見る値:

```text
cycle
minstret
CPI = cycle / minstret
pipeline stall cycles
branch count
branch mispredict count
load/store count
TLB hit / miss
page walk count
I-cache hit / miss
D-cache hit / miss
interrupt count
MMIO access count
```

stallは理由別に分けます。

```text
stall_ptw
stall_ifetch
stall_load
stall_store
stall_muldiv
stall_interrupt
stall_branch
```

この内訳があると、たとえば次のように次の作業を判断できます。

```text
Baseline:
  CPI = 18.4
  PTW stall = 42%
  ifetch stall = 31%

After TLB:
  CPI = 7.2
  PTW stall = 3%
  ifetch stall = 58%

Next:
  I-cache
```

### Keep Performance Blocks Replaceable

TLB、cache、branch predictorをpipelineへ直接埋め込みすぎないようにします。最初はpass-through実装を置ける境界を作ります。

Frontend:

```text
PC generation
branch predictor
ITLB
I-cache
instruction buffer
```

Backend:

```text
decode
execute
mul/div
LSU
DTLB
D-cache
store buffer
```

目標データフロー:

```text
PC
 -> branch predictor
 -> ITLB
 -> I-cache
 -> fetch buffer
 -> decode
 -> execute
 -> LSU
 -> DTLB
 -> D-cache / MMIO
```

最初は次のように置き換え可能にします。

```text
ITLBなし:
  VA -> PTW -> PA

I-cacheなし:
  PA -> memory

branch predictorなし:
  next PC = PC + instruction length
```

### Phase 0: Baseline Freeze

現在のLinux起動状態を基準点として保存します。

```text
git tag linux-baseline
```

具体的な固定手順、実行コマンド、入力列、失敗条件は `Docs/LINUX_BASELINE.md` に従います。
RTLの将来配置とwrapper境界は `Docs/RTL_LAYOUT.md` に従います。

固定する確認項目:

```text
riscv-tests
OpenSBI起動
Linux起動
BusyBox cmdloop
UART入力
echo OK
procfs確認
簡単なファイル操作
```

性能用の最小ベンチも用意します。

```text
Linux boot完了までのcycle
BusyBox /init 到達までのcycle
echo OK 往復までのcycle
100万命令loop
memcpy
branch-heavy loop
page-walk-heavy access
```

### Phase 1: Small TLB

最初の性能機能はTLBを優先します。

初期構成:

```text
ITLB: 8 entry fully associative
DTLB: 8 entry fully associative
replacement: round-robin
ASID: 最初は無視または固定
page size: まず4KiB
sfence.vma: 全entry flush
```

entry例:

```systemverilog
typedef struct packed {
    logic        valid;
    logic [26:0] vpn;
    logic [43:0] ppn;
    logic        r;
    logic        w;
    logic        x;
    logic        u;
    logic        g;
    logic        a;
    logic        d;
} tlb_entry_t;
```

動作:

```text
TLB hit
  -> PA生成
  -> permission check
  -> memory/cacheへ

TLB miss
  -> pipeline停止
  -> 既存PTW起動
  -> refill
  -> 同じaccessを再実行
```

正しさ優先で始めます。superpageは後回しでもよいですが、Linux側で頻繁に使うなら早めに対応します。

### Phase 2: Small I-cache

次はI-cacheを小さく入れます。

初期構成:

```text
capacity: 4KiB or 8KiB
line size: 32B
ways: 1, direct-mapped
replacement: none
write path: none
```

4KiB / 32B lineなら:

```text
lines = 128
index = 7bit
offset = 5bit
tag = remaining PA bits
```

refillは最初から高性能化しなくてよいです。

```text
32B line = 64-bit memory access x 4
```

FSMでlineを埋め、hit時だけfetchを速くするところから始めます。

### Later Performance Work

優先順位:

```text
TLB
I-cache
UART FIFO / interrupt reduction
branch predictor
D-cache
store buffer
mul/div latency
clock frequency / critical path cleanup
```

性能改善は、必ずPhase 0のbaselineと比較します。

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
  -> OpenSBI
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
- `sv39_ptw.sv` に3-level page table walkerを分離し、data-side load/storeとinstruction fetchから利用している
- 4KiB PTEだけを3-level walkする
- 先頭256KiB RAMとdebug MMIO 1ページのidentity mappingでS-mode load/store/fetchが成功する
- 未map addressのloadで `LOAD_PAGE_FAULT`, `stval=fault VA` を確認済み
- `SUM=0/1` によるS-modeからUページへのdata access制御を確認済み
- `MXR=0/1` によるexecute-onlyページのload制御を確認済み
- 非leaf PTEの予約bitとmisaligned superpageはpage faultにする
- 2MiB L1 / 1GiB L2 superpage aliasのloadを確認済み
- A/D bitは現時点ではhardware updateせず、A=0 loadとD=0 storeがpage faultになることを確認済み
- W=0ページへのstoreで `STORE_AMO_PAGE_FAULT`, `stval=fault VA` となり、store副作用が起きないことを確認済み
- root page table A/Bを作り、`satp.PPN` を切り替えると同じVAが別PAを読むことを確認済み
- X=0ページへのfetchで `INSTRUCTION_PAGE_FAULT`, `stval=fault VA` を確認済み
- PTW中のPTE読み出し自体が失敗した場合はpage faultではなく、元アクセス種別に応じたinstruction/load/store access faultにする
- PTWにPTE読み出しエラー用の `mem_error` 入力はあるが、現在のdata busにはerror応答がないため上位では常時0接続
- `Sv39Fault` でPTW内部fault理由を保持し、architecturalな `scause=12/13/15` とは別に波形/debugで原因を追える
- `sfence.vma` はTLBなしのためno-op命令として受ける

未対応:

- PTW中のPTE読み出しに対するbus/PMP error生成
- TLB / ASID
- A/D bitのhardware update要否判断
- permissionの追加仕様差分確認

最初のテスト:

```text
VA 0x8000_0000
  -> Sv39 page table walk
PA 0x8000_0000
```

最初は仮想アドレスと物理アドレスを同じにして、既存S-modeコードがそのまま動くことを確認します。`make test-os2-min-sv39` ではdata-sideのload/store identity mapping、instruction fetch identity mapping、2MiB L1 / 1GiB L2 superpage、未map load page fault、SUM/MXRの基本permission、A/D fault、W=0 store fault、`satp.PPN` 切り替え、X=0 fetch faultまで確認済みです。

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

現在:

- UART baseは `0x10000000`
- byte-spaced register、つまり `THR=base+0`, `LSR=base+5`
- `THR` byte writeでVerilator標準出力へ文字を出す
- `LSR[5]=THRE`, `LSR[6]=TEMT` を常に1、`LSR[0]=DR` を0として返す
- `RBR` は0固定で、受信は未実装
- `DLL/DLM/IER/FCR/LCR/MCR/SCR` は最小保持レジスタとして用意済み
- `IIR` は no interrupt pending として `0x01` を返す
- `make test-uart` で `A` とsuccessまで確認済み
- `make test-uart-regs` で基本保持レジスタと `LCR.DLAB` による `DLL/DLM` 切り替えを確認済み

次:

- DTBに `serial@10000000` を追加する
- Linux earlycon向けに `reg-shift=0`, `reg-io-width=1` を明記する
- OpenSBIまたはLinux earlyconの初期化がこのUARTで進むか確認する

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

現在:

- `platform/riscv_cpu.dts` を追加済み
- `make dtb` で `build/platform/riscv_cpu.dtb` を生成できる
- `platform/bootrom_linux.S` で `a0=hartid=0`, `a1=0x87f00000` を設定して `0x80000000` へジャンプするboot pathを追加済み
- `tools/make_linux_ram_hex.py` でpayloadとDTBを1つのRAM hexにまとめられる
- `make test-linux-bootargs` でLinux boot ABIの `a0/a1` 受け渡しを確認済み
- `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin` で、repo外のOpenSBI `fw_jump.bin` を `0x80000000` へ配置して起動できるtargetを追加済み
- `LINUX_IMAGE_BIN=/path/to/Image` を追加すると、Linux Imageを `0x80200000` へ配置できる
- RAMは `RAM_ADDR_WIDTH=24`, `RAM_DATA_WIDTH=64` に合わせて `0x80000000..0x87ffffff` の128MiBとして記述
- UARTは `serial@10000000`, `compatible = "ns16550a"`, `reg-shift = <0>`, `reg-io-width = <1>` として記述
- CPU ISA文字列は現在確認済みの範囲に合わせて `rv64imac_zicsr`
- `chosen.bootargs` は通常consoleを後回しにし、`earlycon=uart8250,mmio,0x10000000 ignore_loglevel`
- Linux boot ABI用bootromは `a1=0x87f00000` を渡し、DTBはRAM末尾付近へ配置
- PLIC未実装のため、UART interruptはまだ記述していない

確認済み:

- OpenSBI v1.3.1 `FW_JUMP` を `0x80000000` に配置し、UART banner表示まで到達
- OpenSBI generic platformは現在のDTBから `uart8250` consoleを認識する
- OpenSBIから見た次段は `Next Address = 0x80200000`, `Next Arg1 = 0x87f00000`, `Next Mode = S-mode`
- 現在のDTBではCLINT互換nodeを追加し、OpenSBIから `Platform IPI Device : aclint-mswi`、`Platform Timer Device : aclint-mtimer @ 50000000Hz` として認識される想定
- PMPを8 entriesへ拡張し、OpenSBIから `Boot HART PMP Count : 8` として認識済み
- `make test-opensbi-payload OPENSBI_BIN=...` で、OpenSBIから `0x80200000` のS-mode payloadへ入り、`a0=hartid=0`, `a1=DTB address`, SBI Base call、SBI legacy console putcharを確認済み

確認済み:

- Linux Imageを `0x80200000` に配置し、OpenSBIからLinux entryへ渡せる
- `satp` WARLを修正し、未対応Sv57/Sv48を受理せずSv39へ降格できる
- `satp` CSR access / `sfence.vma` でfetchをflushし、Linux `head.S` の高位アドレス遷移を正しく実行できる
- Linux earlyconで `Linux version 6.12.97`、SBI extension、memory init、SLUB、RCU、`riscv-intc`、clocksource、`sched_clock` まで出力できる
- `TRACE_PIPE` 上では `sched_clock` 後も `minstret` が増え、timekeeping/IRQ処理とOpenSBI timer処理を継続している

次:

- traceなしで長時間実行し、最初のpanic/oops/停止点を特定する
- PLIC実装前に、timer interrupt / SBI timer / WFI復帰がLinux上で進んでいるか確認する
- initramfsなしで進める範囲と、initramfs投入が必要な地点を分ける
- PLIC実装後にUART interrupt numberとDTBを一致させる

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

1. Linux通常consoleでUART interruptを使えるか確認する
2. initramfsなしでどこまで進むか確認し、必要なら最小initramfsを作る
3. UART RX/FIFOを必要に応じて追加する
4. PTWメモリエラー発生源とaccess fault経路を整理する
5. `fence.i` / `zifencei` の正式確認を行い、DTB ISA文字列へ反映する

U-mode syscall cleanup、PMP MMIO副作用、PMP部分重複テストは重要ですが、Linux起動を優先する場合はSv39後の補助タスクとして扱います。
