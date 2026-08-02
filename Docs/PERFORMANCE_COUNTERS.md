# Performance Counters

MiNTs-CPU の性能改善は、まずCPIと大まかなstall内訳を見るところから始めます。

現時点の実装は、RTL内部カウンタをVerilator終了時に表示する最小構成です。LinuxやCSR ABIにはまだ公開しません。

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

出力は4行です。

```text
[PERF] cycles=... retired=... cpi_x1000=... ipc_x1000=...
[PERF] primary commit=... no_commit=... mem=... muldiv=... data_hazard=... ifetch=... other=...
[PERF] active mem=... muldiv=... data_hazard=... ifetch=...
[PERF] events branch=... branch_taken=... control_flush=... trap_flush=... load=... store=... ibus_req=... dbus_req=...
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

## Current Limitations

現時点では、まだ次は分かりません。

```text
TLB hit/miss
I-cache hit/miss
D-cache hit/miss
PTW wait cycleの詳細内訳
MMIO device別access count
branch mispredict
```

TLBやcacheを入れる前なので、まずは既存pipelineのCPIと大まかなstallを見る段階です。

現在のCPIは、リセット解除からシミュレーション終了までの全体平均です。特定区間だけを測る `perf_enable/perf_clear` や専用MMIO制御は次段階で追加します。

## Next Counters

次に追加する候補:

```text
perf_ptw_stall_cycle
perf_fetch_fifo_full_cycle
perf_issue_fifo_empty_cycle
perf_mem_load_stall_cycle
perf_mem_store_stall_cycle
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
