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
