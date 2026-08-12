# Performance Counters

MiNTs-CPU の性能改善は、まずCPIと大まかなstall内訳を見るところから始めます。

現時点の実装は、RTL内部カウンタをVerilator終了時に表示する構成です。LinuxやCSR ABIにはまだ公開しません。

## How To Enable

通常実行では何も出ません。

性能サマリを出す場合だけ、simulation plusargを付けます。

```text
+PERF_SUMMARY
```

例:

```bash
DBG_ADDR=0x40000000 \
obj_dir/sim \
  build/test/bootrom.hex \
  build/test/c_tests/debug_output.bin.hex \
  10000 \
  +PERF_SUMMARY
```

Linuxで見る場合は `SIM_EXTRA_ARGS` に渡します。

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=0 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

長時間Linuxを走らせる場合、`+PERF_SUMMARY` は終了時に出ます。`OPENSBI_CYCLES=0` で手動停止する場合は、Ctrl-CではVerilator finalが走らない可能性があります。まずはcycle上限付きの短い区間で使います。

## Current Output

主な出力は以下です。実装中の性能ブロックに応じて、さらに詳細行が出ます。

```text
[PERF] cycles=... retired=... cpi_x1000=... ipc_x1000=...
[PERF] primary commit=... no_commit=... mem=... muldiv=... data_hazard=... ifetch=... other=...
[PERF] active mem=... muldiv=... data_hazard=... ifetch=...
[PERF] events branch=... branch_taken=... control_flush=... trap_flush=... load=... store=... ibus_req=... dbus_req=...
[PERF-CONTROL] branch=... jal=... jalr=... trap=... return=... satp=... sfence=... other=...
[PERF-MEMARB] i_grant=... d_grant=... d_low_grant=... d_low_defer=...
[PERF-MEMARB-STALL] i_wait=... d_high_wait=... d_low_wait=...
[PERF-ICACHE] req=... hit=... fill_hit=... miss=... hit_rate_x1000=...
[PERF-DCACHE] req=... hit=... miss=... hit_rate_x1000=...
[PERF-STOREBUF] enq=... drain=... full_stall=...
[PERF-FETCH-STALL] fifo_full=... control_recovery=... translation_issue=... icache_req=... icache_rsp=...
[PERF-MEMU-STALL] translation=... access_ready=... response=...
[PERF-ITLB] req=... hit=... miss=...
[PERF-DTLB] req=... hit=... miss=...
```

意味:

```text
cycles
  reset解除後のcore内debug cycle

retired
  writebackでretireした命令数。minstretと同じ基準

cpi_x1000
  cycles / retired * 1000

ipc_x1000
  retired / cycles * 1000

commit
  retireが発生したcycle

no_commit
  retireが発生しなかったcycle
```

`retired` はCSR `minstret` とは別の性能測定用retire数です。`minstret` へ書き込むCSR命令も、正常に完了した命令として `retired` には数えます。一方、CSR `minstret` 本体は、`minstret` へのwriteと自動incrementが競合しないように分けています。

primary stallは1cycleにつき1理由だけに分類します。

優先順位:

```text
mem
muldiv
data_hazard
ifetch
other
```

イベントカウンタ:

```text
branch
branch_taken
control_flush
trap_flush
load
store
ibus_req
dbus_req
```

`[PERF-CONTROL]` は `control_flush` の内訳です。

```text
branch
  taken conditional branch

jal / jalr
  unconditional jump redirect

trap
  exception / interrupt entry

return
  mret / sret redirect

satp / sfence
  translation stateを変えるredirect

other
  上記に分類されなかったcontrol redirect
```

原則として、

```text
branch + jal + jalr + trap + return + satp + sfence + other
  == control_flush
```

になるように数えています。Phase 8では、この内訳を見てbranch/jumpだけをEX段へ前倒しするか判断します。

active stallは、commitの有無に関係なく、そのstall条件が成立したcycleを数えます。primary stallはCPI分解用、active stallは各ユニットの待ち時間観測用です。

## First Smoke Result

`debug_output` の短いC testで `+PERF_SUMMARY` が動作することを確認済みです。

例:

```text
Hello,world!
test success!
[PERF] cycles=1268 retired=339 cpi_x1000=3740 ipc_x1000=267
[PERF] primary commit=339 no_commit=929 mem=398 muldiv=0 data_hazard=134 ifetch=105 other=292
[PERF] active mem=398 muldiv=0 data_hazard=134 ifetch=310
[PERF] events branch=14 branch_taken=13 control_flush=16 trap_flush=0 load=80 store=57 ibus_req=373 dbus_req=137
```

数値は実装更新により多少変わります。重要なのは、通常実行では出ず、`+PERF_SUMMARY` で終了時だけ出ることです。

## Linux 300M Cycle Baseline

2026-08-02 に、Linux cmdloop notrace Imageで `300,000,000` cycleの初回測定を記録しました。

実行条件:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=300000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

結果:

```text
[PERF] cycles=300000000 retired=43361299 cpi_x1000=6918 ipc_x1000=144
[PERF] primary commit=43361299 no_commit=256638701 mem=117731783 muldiv=4182267 data_hazard=11660555 ifetch=80757477 other=42306619
[PERF] active mem=126018276 muldiv=4306971 data_hazard=53158503 ifetch=120999891
[PERF] events branch=3445142 branch_taken=1689174 control_flush=3528305 trap_flush=3775 load=8880411 store=5126702 ibus_req=48071968 dbus_req=26534153
```

読み取り:

```text
CPI ~= 6.918
IPC ~= 0.144
primary no_commitの最大要因はmem stall
次にifetch stallが大きい
```

この結果は、TLB/I-cache追加前の比較基準として使います。

## ITLB Connection Smoke

命令fetch側を `instruction_translation` へ接続した後、短いOpenSBI区間で `+PERF_SUMMARY` が完走することを確認しました。

実行条件:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=20000000 \
  SIM_EXTRA_ARGS='+TRACE_HEARTBEAT +PERF_SUMMARY'
```

結果:

```text
[PERF] cycles=20000000 retired=5092277 cpi_x1000=3927 ipc_x1000=254
[PERF] primary commit=5092277 no_commit=14907723 mem=5802872 muldiv=673 data_hazard=2506413 ifetch=1407009 other=5190756
[PERF] active mem=6954309 muldiv=703 data_hazard=9694306 ifetch=1955987
[PERF] events branch=192050 branch_taken=82398 control_flush=350690 trap_flush=6 load=1340106 store=623311 ibus_req=5548337 dbus_req=1963418
```

これは短いOpenSBI区間のsmoke結果であり、Linux 300M baselineとの性能比較値としては使わない。

## ITLB Connection 300M Cycle Result

命令fetch側を `instruction_translation` へ接続した後、Linux cmdloop notrace Imageで `300,000,000` cycle測定を記録しました。

結果:

```text
[PERF] cycles=300000000 retired=18368225 cpi_x1000=16332 ipc_x1000=61
[PERF] primary commit=18368225 no_commit=281631775 mem=20994446 muldiv=25365 data_hazard=8938884 ifetch=232922918 other=18750162
[PERF] active mem=25136047 muldiv=27537 data_hazard=34761799 ifetch=234916624
[PERF] events branch=730932 branch_taken=324965 control_flush=1291575 trap_flush=7 load=4824153 store=2287602 ibus_req=20073736 dbus_req=7111755
```

TLB/I-cache追加前baselineとの差分:

```text
CPI   6.918 → 16.332
IPC   0.144 → 0.061
retired 43,361,299 → 18,368,225
primary ifetch stall 80,757,477 → 232,922,918
primary mem stall    117,731,783 → 20,994,446
```

現時点では性能改善ではなく、fetch側が大きく悪化している。
この時点ではITLB詳細カウンタがなく、原因候補は `instruction_translation` 接続後のblocking path、superpage leaf未キャッシュ、またはflush処理だった。
後続の `[PERF-ITLB]` カウンタで、分岐flushと同じ規模でTLBを消していた問題が見えたため、現在はtranslation cancel用の `flush` とTLB invalidation用の `tlb_flush` を分離している。
さらに `mem_req` と `mem_resp` が一致しないケースに対して、fetcher側でmemory response ownerを保持し、通常instruction fetch応答とPTW応答を分離している。

## Current 300M Performance Timeline

2026-08-03 時点のLinux cmdloop notrace Image、`300,000,000` cycle測定の推移です。

同じ実行条件で比較します。

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=300000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

要約:

```text
stage                         retired     CPI      IPC      primary_mem  primary_ifetch
baseline no TLB/cache         43,361,299  6.918    0.144    117,731,783  80,757,477
ITLB initial broken path      18,368,225  16.332   0.061    20,994,446   232,922,918
ITLB fixed superpage refill   53,176,454  5.641    0.177    151,741,249  28,921,100
I-cache 4KiB 32B early restart 56,871,866 5.275    0.189    144,670,072  29,112,305
ITLB+I-cache+DTLB             72,705,508  4.126    0.242    76,621,356   64,488,078
D-cache 4KiB WT no-alloc      72,689,380  4.127    0.242    76,657,761   64,487,299
Store buffer 4-entry          72,632,625  4.130    0.242    68,000,992   73,268,698
```

読み取り:

```text
ITLB初期版:
  性能改善ではなくregression。
  原因はTLB flush過多、superpage refill不足、fetch/PTW response routing不足。

ITLB修正版:
  2MiB superpage leafをTLBへrefillし、tlb_flushをsatp/sfence.vmaへ限定。
  retiredがbaseline比で約22.6%増加。
  CPIは 6.918 -> 5.641。

I-cache 4KiB 32B early restart:
  retiredがbaseline比で約31.2%増加。
  CPIは 6.918 -> 5.275。
  ITLB修正版からはretiredが約6.9%増加。

ITLB+I-cache+DTLB:
  data側translation cacheをmemunitへ接続。
  DTLB hit率はLinux 300Mでほぼ99.9%。
  retiredはbaseline比で約67.7%増加。
  CPIは 6.918 -> 4.126。

D-cache 4KiB WT no-alloc:
  32B line / direct-mapped / write-through / no-write-allocate。
  300M全体ではDTLB後から大きなCPI改善なし。
  30M early bootではmem stall減少とCPI改善を確認。

Store buffer 4-entry:
  通常RAM storeをD-cache内bufferへenqueueし、downstream readyで完了扱い。
  30M early bootでは CPI 3.434 -> 3.360、primary_mem 6,296,080 -> 5,743,485。
  300M全体ではprimary_memは減るがprimary_ifetchが増え、CPIはほぼ相殺。
```

現在のI-cache構成:

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

300M result:

```text
[PERF-ITLB] req=36391786 bare=0 unsupported=0 lookup=36391786 hit=36389909 miss=1877 hit_fault=0 hit_rate_x1000=999
[PERF-ITLB] ptw start=1877 done=1876 fault=1 miss_cycles=18759 mem_req=3752 mem_resp=3751
[PERF-ITLB] leaf_l0_4k=0 leaf_l1_2m=1875 leaf_l2_1g=0 refill=1875 superpage_refill=1875 flush=1887
[PERF-ICACHE] req=51425487 cacheable=51425487 hit=44045398 fill_hit=4405593 miss=2974496 uncached=0 hit_rate_x1000=942 flush=1887
[PERF-ICACHE] mem_req=11894234 mem_resp=11894234 early_rsp=2853791 lines=128 line_bytes=32
[PERF] cycles=300000000 retired=56871866 cpi_x1000=5275 ipc_x1000=189
[PERF] primary commit=56871866 no_commit=243128134 mem=144670072 muldiv=4804218 data_hazard=13988492 ifetch=29112305 other=50553047
[PERF] active mem=155376964 muldiv=4934344 data_hazard=65438017 ifetch=41855514
[PERF] events branch=5446301 branch_taken=2693892 control_flush=4936811 trap_flush=4155 load=11329674 store=6488419 ibus_req=64823049 dbus_req=37873624
```

I-cache counterの読み方:

```text
hit_rate_x1000=942
  hit + fill_hit をcacheable requestで割った値。
  94.2%程度の命令側hit率。

miss=2,974,496
mem_req=11,894,234
  32B lineを8B x4でrefillするため、missあたり約4 request。

early_rsp=2,853,791
  critical wordをline完成前にCPUへ返した回数。
  missの多くでearly restartが効いている。

fill_hit=4,405,593
  refill中の同一line・受信済みwordに対する応答。
  full non-blocking cacheではないが、sequential fetchの局所性を拾えている。
```

現時点の主なボトルネック:

```text
primary_mem    = 68,000,992
primary_ifetch = 73,268,698
data_hazard    = 16,521,828
```

命令側はITLB + I-cacheで改善し、data側はDTLB + D-cache + store bufferまで入っています。
store buffer drainは低優先度要求としてRAM arbiterへ渡し、I-cache refillを優先できます。
また、cache hit loadについては、store buffer内の未排出storeと同じ8B beat/byte maskで重ならない場合だけ、
store bufferを空にせず先に実行できます。

```text
next:
  1. ALU/WB forwardingのLinux 300M測定
  2. branch penalty reduction
  3. load-use detail counters
  4. store-to-load forwarding
```

ALU/WB forwarding後は、まず既存の `data_hazard` を比較します。
追加の専用counterはまだ入れず、性能ログを増やさない方針です。

## Current 100M Detailed Measurement

2026-08-12時点では、日常の性能比較は300Mよりも100M区間を基本にします。
300Mは重く、変更の初期評価には時間がかかるためです。

Phase 8でcontrol redirectをEX段へ前倒ししました。
Phase 9ではbranch predictionへ入り、`[PERF-BPRED]` を追加しています。

実行条件:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

Phase 8.3 JALR early redirectの100M代表値:

```text
[PERF-FETCH-STALL] fifo_full=7358709 control_recovery=21209244 translation_issue=19079335 translation_req_wait=1 translation_rsp=22025 icache_req=2886299 icache_rsp=6516943 fault=0 no_request=0
[PERF-CONTROL] branch=1951066 jal=669757 jalr=411594 trap=1531 return=1577 satp=13 sfence=2000 other=0
[PERF] cycles=100000000 retired=33557400 cpi_x1000=2979 ipc_x1000=335
[PERF] primary commit=33557400 no_commit=66442600 mem=23745865 muldiv=3254573 data_hazard=794093 ifetch=18691860 other=19956209
[PERF] active mem=30622198 muldiv=3342040 data_hazard=3696792 ifetch=33461572
[PERF] events branch=4123447 branch_taken=1951066 control_flush=3037538 trap_flush=1531 load=5523649 store=3282315 ibus_req=35960255 dbus_req=8861305
```

読み取り:

```text
CPI ~= 2.979
IPC ~= 0.335
Phase 8.1-8.3でJAL/branch/JALR redirectはEX段へ前倒し済み
control_recoveryはまだ約21.2M cyclesで大きい
Phase 9.1 static predictorの100M測定で、ここからの変化を見る
```

次の優先候補:

```text
1. Phase 9.1 static branch predictorの100M測定
2. Whisper lockstep BusyBox autotest pass確認
3. 2-bit PHT predictor
4. BTB / RAS
5. D-cache容量/way/write-back比較
```

## Current Limitations

現時点で、TLB、I-cache、D-cache、store bufferの概要は `+PERF_SUMMARY` で見えます。
まだ見えていない、または粗いものは次です。

```text
PTW wait cycleの詳細内訳
MMIO device別access count
branch predictor hit/miss
store buffer conflict / load wait reason
I/D RAM arbiter pressure
```

現在のCPIは、リセット解除からシミュレーション終了までの全体平均です。特定区間だけを測る `perf_enable/perf_clear` や専用MMIO制御は次段階で追加します。

## Next Counters

次に追加する候補:

```text
perf_ptw_stall_cycle
perf_fetch_fifo_full_cycle
perf_issue_fifo_empty_cycle
perf_mem_load_stall_cycle
perf_mem_store_stall_cycle
perf_storebuf_load_wait_cycle
perf_storebuf_forward_count
perf_storebuf_load_bypass_count
perf_ram_arb_i_grant_count
perf_ram_arb_d_grant_count
perf_mmio_req_count
perf_interrupt_count
perf_enable / perf_clear
perf_ctrl MMIO
```

TLB実装時に追加する候補:

```text
itlb_lookup
itlb_hit
itlb_miss
dtlb_lookup
dtlb_hit
dtlb_miss
ptw_start
ptw_done
ptw_fault
```

## Translation Counters

`instruction_translation` / `data_translation` は、`+PERF_SUMMARY` の終了時だけtranslation単位のsummaryを出します。
通常実行では出ません。

命令側は `PERF_NAME="ITLB"`、データ側は将来接続時に `PERF_NAME="DTLB"` として表示します。

出力例:

```text
[PERF-ITLB] req=... bare=... unsupported=... lookup=... hit=... miss=... hit_fault=... hit_rate_x1000=...
[PERF-ITLB] ptw start=... done=... fault=... miss_cycles=... mem_req=... mem_resp=...
[PERF-ITLB] leaf_l0_4k=... leaf_l1_2m=... leaf_l2_1g=... refill=... superpage_refill=... flush=...
```

`flush` は `tlb_flush` 回数、つまり `satp` write / `sfence.vma` によるTLB invalidation回数です。
branch/trap/control redirectによるtranslation cancelは、この値には含めません。

`mem_req` と `mem_resp` は、PTWへ渡されたPTE read request/responseです。
この2つが長時間実行後に大きくずれる場合、fetch memory response routingを疑います。

見るべき点:

```text
lookup / hit / miss
  ITLBが効いているかを見る

hit_rate_x1000
  hit率 * 1000

miss_cycles
  PTW待ちで消えたcycle

leaf_l0_4k
  4KiB leaf。現在のTLBへrefillされる

leaf_l1_2m / leaf_l2_1g
  superpage leaf。現在はTLBへ登録する

superpage_refill
  2MiB/1GiB superpage leafをTLBへ登録した回数
```

Sv39のページウォークは、通常の4KiB pageなら最大3回PTEを読みます。
2MiB superpageなら2回、1GiB superpageなら1回でleafに到達します。
Hypervisorの二段変換はまだ実装対象外なので、現時点のMiNTs-CPUでは最大3段です。

次の判断:

```text
missが多く leaf_l0_4k が多い
  4KiB ITLB容量や置換が主因

missが多く leaf_l1_2m / leaf_l2_1g が多いがhit率が上がらない
  superpage TLBのmatch幅やPA合成を確認

mem_req / miss が3に近い
  4KiB page walkが多い。中間PTEを保持するpage-walk cacheが候補

hit率が高いのにCPIが悪い
  TLB hitでもResponse状態を通るblocking fetch pathが主因
```
