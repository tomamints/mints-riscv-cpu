# Roadmap

この文書は、現在の **MiNTs-CPU** を、Linuxが動くSoCプロトタイプから、測定可能で改善しやすいCPUへ育てるための作業順序を整理したものです。

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
- BusyBox initramfsの `autotest` で `BUSYBOX-TEST-PASS` まで到達する
- Whisper lockstepでBusyBox autotest passを検出し、約61.6M命令比較後に正常停止する

現在のLinux / lockstep観測点:

- UART THRE interruptは、LinuxのIIR readでpendingをclearする
- `mip/sip.SEIP` はPLIC外部信号で決まり、CSR writeで内部にラッチしない
- `sret/mret` は `SPIE/MPIE` を仕様どおり復元する
- `WFI` が割り込みでtrapへ入る場合、RTLのEPCはWFIの次PCになり、Whisper側もlockstepで補正する
- instruction fetch page faultのSTVALはfetch block baseではなくarchitectural fault PCを返す
- RTLでは `mtime` が毎CPUクロック増えるため、DTBの `timebase-frequency` はCPU clock想定の50MHzへ合わせる
- 次は性能カウンタで見えているMEM側固定レイテンシとcontrol recoveryを順に減らす
- default対話shellは継続確認するが、回帰基準は `autotest` とlockstep passに置く

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

initial branch predictor bypass:
  next PC = PC + instruction length
```

### Phase 0: Baseline Freeze

現在のLinux起動状態を基準点として保存します。

```text
git tag linux-baseline
```

具体的な固定手順、実行コマンド、入力列、失敗条件は `Docs/LINUX_BASELINE.md` に従います。
RTLの将来配置とwrapper境界は `Docs/RTL_LAYOUT.md` に従います。
性能カウンタの現在の使い方は `Docs/PERFORMANCE_COUNTERS.md` に記録します。

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
page size: 4KiB / 2MiB superpage / 1GiB superpage
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

現在の状態:

```text
ITLB:
  接続済み
  8 entry fully associative
  Sv39 4KiB / 2MiB / 1GiB leaf refill対応
  satp write / sfence.vma で全flush
  Linux 300Mで hit_rate_x1000=999

DTLB:
  接続済み
  8 entry fully associative
  Sv39 4KiB / 2MiB / 1GiB leaf refill対応
  satp write / sfence.vma で全flush
  Linux 300Mで hit_rate_x1000=999
```

TLB導入後の300M Linux測定:

```text
baseline no TLB/cache:
  retired=43,361,299
  CPI=6.918

ITLB fixed superpage refill:
  retired=53,176,454
  CPI=5.641

ITLB + I-cache + DTLB:
  retired=72,705,508
  CPI=4.126
```

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

現在は、最小blocking refillから一段進めて、critical-word-first / early restartまで入れています。

```text
32B line = 64-bit memory access x 4
```

現在の構成:

```text
capacity: 4KiB
line size: 32B
lines: 128
ways: 1 direct-mapped
refill: 4 x 8B
policy: critical-word-first, early restart
fill buffer: 1 entry
hit-under-refill: same fill line only
```

I-cache導入後の300M Linux測定:

```text
ITLB fixed superpage refill:
  retired=53,176,454
  CPI=5.641

I-cache 4KiB 32B early restart:
  retired=56,871,866
  CPI=5.275
  I-cache hit_rate_x1000=942
```

この時点で命令側は一定改善したため、次の本命はdata sideです。

### Phase 3: DTLB / Data Side

DTLBは `memunit` 側へ接続済みです。

現在の構成:

```text
DTLB: 8 entry fully associative
access type: load=read, store/AMO=write
SUM/MXR: sstatusから反映
miss: 既存PTWを使用
sfence.vma/satp: 全flush
```

最初に見る値:

```text
[PERF-DTLB] lookup / hit / miss
[PERF-DTLB] miss_cycles
[PERF-DTLB] mem_req / mem_resp
[PERF] primary mem
[PERF] dbus_req
```

Linux 300M測定では、DTLB hit率はほぼ99.9%です。data page walkは主因ではなくなったため、次はD-cacheへ進みました。

### Phase 4: Small D-cache

D-cacheは小型in-order CPU向けの保守的な構成から始めています。

現在の構成:

```text
capacity: 4KiB
line size: 32B
lines: 128
ways: 1 direct-mapped
write policy: write-through
store miss policy: no-write-allocate
refill: 4 x 8B
load refill: critical-word-first
AMO/LR/SC: bypass
MMIO/uncached: bypass
```

D-cacheは物理アドレス後段に置きます。

```text
LSU / memunit
 -> DTLB / translation
 -> D-cache
 -> AMO unit
 -> membus / MMIO / RAM
```

AMOはD-cacheをbypassし、対象lineがcache hitしていればlineをinvalidateします。単一core・write-through cacheとして、まず正しさを優先します。

Linux 300M測定:

```text
ITLB + I-cache + DTLB:
  retired=72,705,508
  CPI=4.126
  primary_mem=76,621,356

with D-cache:
  retired=72,689,380
  CPI=4.127
  primary_mem=76,657,761
```

D-cache単体では、300M全体では大きな改善は出ませんでした。ただし30Mのearly boot区間ではmem stallを減らし、CPI改善が見えています。

### Phase 5: Store Buffer

write-through storeでCPUが待つ時間を隠すため、D-cache内に小さいstore bufferを追加しました。

現在の構成:

```text
depth: 4 entry
対象: 通常RAM store
完了条件: downstream readyでstore完了
drain: 背後でwrite-through
load: cache hitかつstore buffer内の未排出storeと同一8B beat/byte maskで重ならない場合は先行可能
AMO/MMIO/uncached/load miss: store bufferが空になるまで待つ
drain priority: count 0-2は低優先度、count 3-4またはempty待ち要求ありなら緊急
store-to-load forwarding: なし
unrelated load bypass: cache hit loadのみ対応
```

30M測定では改善します。

```text
D-cache only:
  retired=8,734,585
  CPI=3.434
  primary_mem=6,296,080

store buffer fixed:
  retired=8,927,963
  CPI=3.360
  primary_mem=5,743,485
```

一方、300M測定ではmem stall減少をifetch stall増加が相殺しています。

```text
D-cache/DTLB before store buffer:
  retired=72,705,508
  CPI=4.126
  primary_mem=76,621,356
  primary_ifetch=64,488,078

store buffer:
  retired=72,632,625
  CPI=4.130
  primary_mem=68,000,992
  primary_ifetch=73,268,698
```

store buffer自体は動作していますが、単一RAM portをI-cache refillと奪い合います。
そのため、store drainには低優先度sidebandを持たせ、通常時はI-cache refillを優先します。
ただしstore buffer occupancyが `depth-1` 以上の時や、load/AMO/MMIO/uncachedがbuffer emptyを待つ場合は、store drainを緊急扱いにします。

さらに、cache hit loadについては、store buffer内の未排出storeとbyte範囲が重ならない場合だけ先行可能にしました。
load missはline fillで古いRAM内容をcacheへ入れる危険があるため、まだstore buffer empty待ちです。

ここで Phase 5 の初期store bufferは一旦complete扱いにします。
残るstore-to-load forwarding、partial forwarding、store coalescingは、後の測定でstore-load待ちが主因として残った場合に戻ります。

### Later Performance Work

優先順位:

```text
done:
  ITLB
  I-cache
  DTLB
  D-cache
  store buffer initial
  store drain priority control
  unrelated load bypass
  ALU/WB forwarding
  MEM-side DTLB-hit fast path
  JAL early redirect
  conditional branch early redirect
  JALR early redirect
  static branch predictor module split

next:
  2-bit PHT predictor 100M measurement
  Whisper lockstep check for predictor path
  D-cache write-back
  RAM arbiter / I-D memory port pressure reduction

later:
  BTB / RAS
  UART FIFO / interrupt reduction
  mul/div latency
  clock frequency / critical path cleanup
```

性能改善は、必ずPhase 0のbaselineと比較します。

### Phase 6: ALU / WB Forwarding

目的:

```text
不要なdata hazard stallを減らす
load-useだけを本当に必要なstallとして残す
```

実装:

```text
MEM -> EX:
  ALU/LUI/JALなど、MEM段で結果が確定しているrdだけforward

WB -> EX:
  load/CSRを含め、trapしていないwriteback結果をforward

stall継続:
  MEM段のload/AMO/CSR依存は、結果がまだ安全に使えないためstall
```

これにより、従来は全部止めていた次の依存を通せます。

```text
add x3, x1, x2
add x4, x3, x5   // MEM -> EX forward

ld  x3, 0(x1)
add x4, x3, x5   // load-useなので1段待ってWB -> EX forward
```

期待する測定変化:

```text
primary data_hazard減少
active data_hazard減少
CPI改善
```

現在の状態:

```text
ALU/WB forwardingは導入済み。
100M Linux区間ではCPI 3.043 -> 2.938 まで改善した。
300M区間ではmemory/cache待ちが支配的で、改善効果は他のstallに隠れやすい。
```

### Phase 7: MEM-Side Fast Path

現在の性能カウンタでは、D-cache単体よりも `memunit` の固定レイテンシが目立っています。

100M Linux測定例:

```text
[PERF] cycles=100000000 retired=34025923 cpi_x1000=2938 ipc_x1000=340
[PERF-MEMU-STALL] translation=4238618 access_ready=12605077 response=10749236
```

次の狙い:

```text
DTLB hit時のtranslation固定cycle削減
D-cache hit時のrequest/response固定cycle削減
load miss / uncached / store drainとの分類維持
```

最初から完全な組み合わせfast pathへ寄せるのではなく、FPGAでのcritical pathを壊さない範囲で1cycleずつ削る方針です。

### Phase 8: Branch / Control Redirect

`control_flush` とfetch recoveryを減らすため、正解が分かった後のredirectを早めます。
このPhaseではpredictor stateは持たず、EX段で確定した事実だけを使います。

完了済み:

```text
Phase 8.0:
  control redirect内訳counter

Phase 8.1:
  JAL early redirect

Phase 8.2:
  conditional branch early redirect

Phase 8.3:
  JALR early redirect
```

直近100M代表値:

```text
Phase 8.3:
  cycles=100000000
  retired=33557400
  cpi_x1000=2979
  ipc_x1000=335
  primary_ifetch=18691860
  control_flush=3037538
```

trap/interrupt/exception/mret/sret/sfence/satp redirectは、precise boundaryを壊さないためMEM/CSR側を正として維持します。

### Phase 9: Branch Prediction

Phase 9は、EXで正解が分かる前にfrontend側で次PCを予測する段階です。

現在の状態:

```text
Phase 9.0:
  branch_predictor.sv を追加
  inst_fetcher.sv からstatic predictorロジックを切り出し

Phase 9.1:
  static backward-taken / forward-not-taken predictor
  prediction metadataをissue FIFO経由でEXへ渡す
  EXで予測hit/missを判定
  miss時だけ正しいPCへredirect
  [PERF-BPRED] を追加

Phase 9.2:
  128-entry 2-bit PHT predictor
  未学習entryはBTFNTへfallback
  EX段のresolved branchでPHT更新
  100M measurement pass
  Whisper BusyBox autotest lockstep pass

Phase 9.3:
  32-entry JALR BTB
  PHT updateとBTB updateを種別で分離
  core redirectはpredictionより常に優先
  100M measurement pass
  Whisper BusyBox autotest lockstep pass

Phase 9.4:
  JALR call/return/other classification counter
  8-entry non-speculative RAS
  return prediction uses RAS > BTB priority
  [PERF-JALR] and [PERF-RAS] counters
  100M measurement pass
```

B-type branchのtargetは命令即値から計算しています。
BTBは最初の段階としてJALR target predictionに限定しています。

Phase 9.4の100M代表値:

```text
[PERF-JALR] call=35328 return=349378 other=32157
[PERF-RAS] return=349378 hit=325546 miss=23832 fallback_btb=771 hit_rate_x1000=931 depth=8
[PERF] cycles=100000000 retired=36690014 cpi_x1000=2725 ipc_x1000=366
[PERF] primary commit=36690014 no_commit=63309986 mem=25359068 muldiv=3264316 data_hazard=804410 ifetch=14451685 other=19430507
```

残る確認:

```text
Whisper lockstep BusyBox autotest pass
```

### Phase 10: MEM/LSU Latency Reduction

Phase 10では、branch predictionで減ったcontrol stallの次に大きく残っているMEM側を扱います。
いきなりD-cache構成を変えるのではなく、まずmemunit/D-cache間の固定レイテンシと、本当にmemory/cacheを待っている時間を分けます。

現在の入口:

```text
primary mem is still the largest primary stall class
DTLB hit rate is high
D-cache miss and uncached access are visible
memunit translation/access/response states still consume many cycles
```

Phase 10.0:

```text
[PERF-MEMU-FIXED] を追加
translation_done / access_accept / response_doneを表示
既存のwait総数からbus waitを引き、固定FSM cycleを見える化する
```

Phase 10.1以降の候補:

```text
DTLB hit fast path
memunit AccessWaitReady固定cycle削減
D-cache hit response latency削減
D-cache容量/way比較
write-through traffic削減またはwrite-back化
```

Phase 10の判断基準:

```text
fixed FSM cycleが大きい:
  memunit fast pathを優先

D-cache miss stallが大きい:
  4KiB direct / 8KiB direct / 4KiB 2-wayを比較

write-through / drain trafficが支配的:
  write-back D-cacheまたはwrite combiningを検討
```

### Correctness Guard: PMP After Translation

Sv39有効時、data PMPは仮想アドレスではなく変換後の物理アドレスに対して行う必要があります。

現在の整理:

```text
I-fetch:
  instruction_translation後のphysical PCへPMP EXEC check

load/store/AMO:
  memunit内でBare時は元アドレス、Sv39時はtranslation_paへPMP READ/WRITE check

PTW:
  address_translation内でPTE read物理アドレスへPMP READ check
  PMP拒否時は外部memoryへrequestを出さず、PTWへmem_errorとして返す
```

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
