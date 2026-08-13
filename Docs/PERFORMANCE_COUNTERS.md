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
[PERF-DCACHE-WB] enabled=... store_hit=... evict=... words=... req_wait=...
[PERF-DCACHE-WB-FLUSH] clean=... dirty=... scan=... dirty_lines=... words=... req_wait=...
[PERF-DCACHE-MIX] load_hit=... load_miss=... store_hit=... store_miss=...
[PERF-DCACHE-RSP] hit_load=... fill_critical=... bypass_load=... bypass_amo=...
[PERF-DCACHE-FAST] hit_load=...
[PERF-STOREBUF] enq=... drain=... full_stall=...
[PERF-STOREBUF-OCC] empty=... one=... two=... almost_full=... full=...
[PERF-STOREBUF-DRAIN] urgent_active=... urgent_wait=... low_active=... low_wait=...
[PERF-STOREBUF-COMBINE] candidate=... tail_word=... tail_disjoint=... any_word=... any_line=...
[PERF-FETCH-STALL] fifo_full=... control_recovery=... translation_issue=... icache_req=... icache_rsp=...
[PERF-MEMU-STALL] translation=... access_ready=... response=...
[PERF-MEMU-FIXED] translation_done=... access_accept=... response_done=...
[PERF-MEMU-RSPDONE] load=... amo=... split_first=... split_second=...
[PERF-MEMU-FAST] hit_load=...
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
Phase 9.3ではJALR用BTBを追加し、`[PERF-BTB]` を追加しています。
Phase 9.4ではreturn用RASを追加し、`[PERF-JALR]` と `[PERF-RAS]` を追加しています。

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
Phase 9.1 static predictorでCPIは約2.879まで改善
Phase 9.2 2-bit PHT predictorでCPIは約2.812まで改善
Phase 9.3 JALR BTBでCPIは約2.765まで改善
Phase 9.4 RASでCPIは約2.725まで改善
```

Phase 9.1 static predictorの100M代表値:

```text
[PERF-CONTROL] branch=1236016 jal=677463 jalr=412335 trap=1539 return=1585 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=4329566 hit=3093544 miss=1236022 hit_rate_x1000=714
[PERF] cycles=100000000 retired=34725769 cpi_x1000=2879 ipc_x1000=347
```

Phase 9.2 2-bit PHT predictorの100M代表値:

```text
[PERF-FETCH-STALL] fifo_full=7310937 control_recovery=18067125 translation_issue=19530511 translation_req_wait=1 translation_rsp=22025 icache_req=3162327 icache_rsp=6567639 fault=0 no_request=0
[PERF-CONTROL] branch=670026 jal=683660 jalr=413289 trap=1551 return=1599 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=4473131 hit=3803100 miss=670031 hit_rate_x1000=850
[PERF] cycles=100000000 retired=35561702 cpi_x1000=2812 ipc_x1000=355
[PERF] primary commit=35561702 no_commit=64438298 mem=24715916 muldiv=3262066 data_hazard=803987 ifetch=15958545 other=19697784
[PERF] events branch=4473083 branch_taken=2157035 control_flush=1772138 trap_flush=1551 load=5893304 store=3425600 ibus_req=36898779 dbus_req=9376259
```

Phase 9.3 JALR BTBで追加される行:

```text
[PERF-BTB] jalr=<resolved_jalr> hit=<btb_hit> miss=<btb_miss> hit_rate_x1000=<hit_rate> entries=32
```

Phase 9.3 JALR BTBの100M代表値:

```text
[PERF-FETCH-STALL] fifo_full=6897245 control_recovery=18065095 translation_issue=19683309 translation_req_wait=1 translation_rsp=22025 icache_req=3108269 icache_rsp=6523760 fault=0 no_request=0
[PERF-CONTROL] branch=691084 jal=687433 jalr=245294 trap=1571 return=1619 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=4582433 hit=3891348 miss=691085 hit_rate_x1000=849
[PERF-BTB] jalr=416164 hit=168874 miss=247290 hit_rate_x1000=405 entries=32
[PERF] cycles=100000000 retired=36163117 cpi_x1000=2765 ipc_x1000=361
[PERF] primary commit=36163117 no_commit=63836883 mem=25062608 muldiv=3266929 data_hazard=809858 ifetch=15175087 other=19522401
[PERF] events branch=4582395 branch_taken=2223578 control_flush=1629014 trap_flush=1571 load=6005189 store=3464265 ibus_req=37334673 dbus_req=9526809
```

Phase 9.4 RASで追加される行:

```text
[PERF-JALR] call=<jalr_call> return=<jalr_return> other=<jalr_other>
[PERF-RAS] return=<resolved_return> hit=<ras_hit> miss=<ras_miss> fallback_btb=<btb_correct_without_ras> hit_rate_x1000=<hit_rate> depth=8
```

Phase 9.4 RASの100M代表値:

```text
[PERF-FETCH-STALL] fifo_full=6887044 control_recovery=17304428 translation_issue=19794373 translation_req_wait=1 translation_rsp=22025 icache_req=2924354 icache_rsp=6440364 fault=0 no_request=0
[PERF-CONTROL] branch=709863 jal=691910 jalr=64056 trap=1575 return=1623 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=4670833 hit=3960960 miss=709873 hit_rate_x1000=848
[PERF-BTB] jalr=416863 hit=352805 miss=64058 hit_rate_x1000=846 entries=32
[PERF-JALR] call=35328 return=349378 other=32157
[PERF-RAS] return=349378 hit=325546 miss=23832 fallback_btb=771 hit_rate_x1000=931 depth=8
[PERF] cycles=100000000 retired=36690014 cpi_x1000=2725 ipc_x1000=366
[PERF] primary commit=36690014 no_commit=63309986 mem=25359068 muldiv=3264316 data_hazard=804410 ifetch=14451685 other=19430507
[PERF] events branch=4670779 branch_taken=2273603 control_flush=1471040 trap_flush=1575 load=6097470 store=3510175 ibus_req=37730515 dbus_req=9665000
```

Phase 10では、MEM/LSU側を次のように分けて見ます。

```text
[PERF-MEMU-FIXED]
  translation_done
    translation responseが返っており、PTWやrsp waitではないtranslation完了cycle

  access_accept
    AccessWaitReady中にmembus.readyが立っていて、実待ちではなくrequest acceptに使ったcycle

  response_done
    AccessWaitValid中にdata responseが返っていて、実待ちではなくload/AMO応答完了に使ったcycle

  split_accept / split_response_done
    misaligned split accessのsecond beatで同じ基準を見た値
```

この行は新しい独立カウンタではなく、既存のwait総数からbus waitを引いた派生値です。
値が大きい場合、D-cache missやMMIO待ちではなく、memunit/D-cache間の固定FSMレイテンシを減らす候補になります。

`[PERF-DCACHE-RSP]` は、D-cacheがCPU側へload/AMO応答を返した理由を分けます。

```text
hit_load
  cacheable load hitで、D-cache data arrayから応答した回数

fill_critical
  cache miss refill中にcritical wordが返り、CPUへearly responseした回数

bypass_load
  uncached/MMIO loadなど、cacheを通さずmemory応答をCPUへ返した回数

bypass_amo
  AMO/LR/SCなど、bypass経路のread-modify-write応答をCPUへ返した回数
```

`response_done` が大きく、かつ `hit_load` が大きい場合は、D-cache hit load responseの固定1cycleを詰める候補になります。

`[PERF-MEMU-RSPDONE]` は、memunitが `AccessWaitValid` / `SplitAccessWaitValid` でD-cache/data応答を実際に受け取った完了cycleを種類別に数えます。

```text
load
  non-split loadでdata_mem_rvalidを見たcycle

amo
  AMO/LR/SC応答でdata_mem_rvalidを見たcycle

split_first
  misaligned split accessのfirst beat responseを見て、second beatへ進めるcycle

split_second
  misaligned split accessのsecond beat responseを見て、全体を完了するcycle
```

この行は、`response_done` が「rvalid後に残る余分な後処理cycle」なのか、「rvalid到着そのものの完了cycle」なのかを確認するためのものです。現在のnon-split loadでは、`AccessWaitValid` のstall条件が `!data_mem_rvalid` なので、`load` に数えられるcycleではCPU側のmemunit stallは解除されます。したがって `load` が `response_done` の大部分を占める場合、memunit内のpost-rvalid bubbleを消す余地は小さく、次に狙うならD-cache側の登録応答を保ったままではなく、passiveなhit/data sidebandなど別interfaceでhit loadを早く返す必要があります。

Phase 10.2では、D-cache hit load用に通常`valid/ready/rvalid`とは別のpassive sidebandを追加します。

```text
[PERF-DCACHE-FAST]
  hit_load
    D-cacheがsidebandで安全に返せたcacheable normal load hit数

[PERF-MEMU-FAST]
  hit_load
    memunitがsideband結果を使って通常request/registered rvalidを待たずに完了したload数
```

このfast pathは、通常のD-cache responseを組み合わせ化するものではありません。memunitが物理アドレス、funct3、load条件をsidebandへ出し、D-cacheが次を満たす場合だけ `fast_load_valid/data` を返します。

```text
D-cache Idle
既存response pendingなし
RAM/cacheable address
tag hit
store buffer overlapなし
invalidate中ではない
```

fast hit時はmemunitが通常D-cache requestを発行せず、そのcycleでloadを完了します。missまたはunsafeなら従来のD-cache requestへ落ちるため、既存のmiss/refill、uncached/MMIO、AMO、split accessの動作は維持されます。

Phase 10.3では、fast load後に見え始めたstore/write-through圧力を分けます。

```text
[PERF-DCACHE-MIX]
  load_hit / load_miss
    cacheable loadのhit/miss数。fast hit loadもload_hitに含める

  store_hit / store_miss
    cacheable storeのhit/miss数。どちらもwrite-through storeとしてstore bufferへenqueueされる

[PERF-STOREBUF-OCC]
  empty / one / two / almost_full / full
    store buffer occupancyごとのcycle数

[PERF-STOREBUF-DRAIN]
  urgent_active / urgent_wait
    full近傍、load/AMO/MMIO待ちなどでurgent扱いされたstore drainのactive/wait cycle

  low_active / low_wait
    background扱いのstore drain active/wait cycle

[PERF-STOREBUF-COMBINE]
  candidate
    store bufferへenqueueされたcacheable store数。write combining対象の母数

  tail_word
    直前にenqueueされたtail entryと同じ8-byte wordへのstore数。
    FIFO順序を大きく崩さずにmergeしやすい候補

  tail_disjoint
    tail_wordのうち、byte maskが重ならないstore数。
    部分store同士を単純OR maskでまとめやすい候補

  any_word
    store buffer内のどこかに同じ8-byte wordのpending storeがあった数。
    tail_wordより広い上限見積もりで、実装には順序制御が必要

  any_line
    store buffer内のどこかに同じcache lineのpending storeがあった数。
    line-level combiningやwrite-back化の参考値
```

読み方:

```text
store_missが大きい:
  write-through以前にstore locality/cache容量の問題がある

store_hitが大きく、drain_activeも大きい:
  storeはcache hitしているがwrite-through trafficがmemory bandwidthを消費している

full occupancy / urgent_wait / store_fullが大きい:
  store buffer depth、drain priority、write combiningの候補

low_waitだけ大きい:
  background drainが遅れているだけで、CPU critical stallとは限らない

tail_wordが大きい:
  小さいwrite combiningでwrite-through trafficを減らせる可能性が高い

any_wordは大きいがtail_wordが小さい:
  merge機会はあるが、FIFO順序やstore orderingを崩さず扱う設計が必要

any_lineが大きい:
  word combiningより、line単位のwrite combining/write-backの方が効く可能性がある
```

store buffer depthのA/B実験は、同じRTLからMake変数で切り替えます。

```bash
make build-input DCACHE_STORE_BUFFER_DEPTH=8

make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY \
  2>&1 | tee /tmp/perf-100m-storebuf8.log
```

比較する主な値:

```text
CPI
[PERF-STOREBUF] full_stall / depth
[PERF-STOREBUF-OCC] full / almost_full
[PERF-STOREBUF-DRAIN] urgent_wait / low_wait
[PERF-STOREBUF-COMBINE] tail_word / any_word / any_line
[PERF] primary mem / ifetch / other
```

`full_stall` が消えてもCPIやdrain waitがほぼ変わらない場合、主因はbuffer容量ではなくwrite-through downstream bandwidthです。

D-cache容量のA/B実験も、同じMake変数で切り替えます。まず256 linesを見て、改善が残る場合は512 linesも測ります。

```bash
make build-input DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8

make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY \
  2>&1 | tee /tmp/perf-100m-dcache512-sb8.log
```

比較する主な値:

```text
[PERF-DCACHE] hit_rate_x1000 / mem_req / write_through
[PERF-DCACHE-MIX] load_miss / store_miss
[PERF-DSTALL] load_miss
[PERF] cycles / primary mem
```

`load_miss` と `store_miss` が大きく減れば容量不足が効いています。missが減らずwrite_through/drain waitが残る場合は、容量よりwrite-through traffic側を優先します。

Phase 10.5では、実験的なD-cache write-back modeをMake変数で切り替えます。

```bash
make build-input DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=1

make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY \
  2>&1 | tee /tmp/perf-100m-dcache512-sb8-wb.log
```

初期版は保守的な構成です。

```text
cacheable store hit:
  D-cacheを更新しdirty bitを立てる
  store bufferへenqueueしない
  RAMへwrite-throughしない

cacheable store miss:
  no-write-allocateのままstore buffer経由でwrite-through

dirty victimを伴うload miss:
  victim lineを4 word writebackしてからrefill

dirty hit lineへのAMO:
  victim lineを書き戻してinvalidateしてから従来のAMO bypassへ進む
```

`[PERF-DCACHE-WB]` はwrite-back modeの動作量を示します。

```text
enabled
  1ならwrite-back実験モード有効、0なら従来write-through

store_hit
  write-throughを省略し、dirty cache lineへ吸収したstore hit数

evict
  dirty line writebackを開始した回数

words
  dirty line writebackで発行した64-bit write数

req_wait
  dirty writeback requestがmemory ready待ちしたcycle数
```

`[PERF-DCACHE-WB-FLUSH]` は、translation flushに伴うwrite-back flushの内訳です。

```text
clean
  flush要求時にdirty lineもstore buffer pendingもなく、scanせず即完了できた回数

dirty
  dirty lineまたはstore buffer pendingがあり、D-cache flush処理へ入った回数

scan
  FlushScan状態でlineを調べたcycle数

dirty_lines
  flush処理由来でwritebackしたdirty line数

words
  flush処理由来でwritebackした64-bit word数

req_wait
  flush処理由来のdirty writeback requestがmemory ready待ちしたcycle数
```

`clean` が多い場合は `dirty_any` fast skip が効きます。`dirty` と `dirty_lines` が多い場合は、`SFENCE.VMA/satp` とD-cache full flushの分離、またはPTWをD-cache coherentにする設計が本命になります。

比較する主な値:

```text
[PERF-DCACHE] write_through / mem_req / mem_resp
[PERF-DCACHE-WB] store_hit / evict / words / req_wait
[PERF-STOREBUF] enq / drain / full_stall
[PERF-STOREBUF-DRAIN] urgent_wait / low_wait
[PERF-DSTALL] load_miss / uncached / storebuf_full
[PERF] cycles / primary mem / ifetch / other
```

write-back modeはまだ実験用です。`satp`更新や`SFENCE.VMA`によるtranslation flush時は、D-cacheがstore bufferをdrainし、dirty lineをwritebackしてからpipeline redirectを完了します。これにより、PTWがRAM上の古いPTEを読む問題を避けます。

ただし、このflushは保守的な全line writeback/invalidateです。将来、明示的なD-cache invalidate命令やDMA coherenceを扱う場合は、今回のflush機構をその用途にも接続するか、より細かいwriteback/invalidate制御へ拡張する必要があります。

次の優先候補:

```text
1. Phase 9.4 Whisper lockstep BusyBox autotest pass確認
2. Phase 10 MEM/LSU fixed latencyの定量化
3. D-cache容量/way/write-back比較
4. 必要ならspeculative RAS recovery / larger BTB
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
