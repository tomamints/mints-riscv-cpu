# Address Translation Development Plan

MiNTs-CPU の性能改善は、まず ITLB から進める。

## Current State

追加済み:

```text
rtl/mmu/tlb.sv
rtl/mmu/address_translation.sv
rtl/mmu/instruction_translation.sv
rtl/mmu/data_translation.sv
tb/unit/tlb/tb_tlb.sv
tb/unit/tlb/tb_address_translation.sv
```

`tlb.sv` / `address_translation.sv` / `instruction_translation.sv` は `core.f` に追加済み。
`data_translation.sv` はまだLSUへ接続していない。

ここで作った `tlb.sv` は address translation 全体ではなく、変換結果を保持する小さな部品です。
CPU本体へ見せる境界は、TLBとPage Table Walkerをまとめた translation unit にします。

```text
CPU request
  ↓
instruction_translation / data_translation
  ├─ satp.MODE select
  ├─ TLB lookup
  ├─ PTW on miss
  └─ TLB refill
  ↓
physical address or page fault
```

## First TLB Module

最初のTLBは共通部品として作る。

```text
entry count      8
lookup           fully associative
replacement      round-robin
page size        4 KiB / 2 MiB / 1 GiB
ASID             not implemented yet
flush            all entries invalidated
permissions      R/W/X/U/A/D checked on hit
```

ITLB用途では主に次を見る。

```text
X bit
U bit
A bit
S/U privilege
```

DTLBへ流用するため、`R/W/D/SUM/MXR` もこの段階で扱う。

## PTW Refill Outputs

`src/sv39_ptw.sv` は、TLB refill用にleaf情報を返すように拡張済み。

追加した出力:

```text
leaf_valid
leaf_pte
leaf_level
```

既存のfetch/data側PTWインスタンスでは、このleaf情報は未使用wireへ接続している。

PTW本体側では、接続前に以下も整理済み。

```text
PTE lane selection:
  MEMBUS_DATA_WIDTH が64bitより広い場合も、pte_addrに対応する64bit laneを選択する

flush with outstanding PTW read:
  request受理後にflushされた場合は DrainResp で古いresponseを捨ててからIdleへ戻る

canonical check naming:
  start_va_canonical として、start時入力VAの判定であることを明示
```

## Current Connection

命令fetch側は、既存のfetch専用 `sv39_ptw` 直接接続から `instruction_translation` へ置き換え済み。
データ側はまだ既存の `memunit.sv` から `sv39_ptw` を直接使っている。

fetch側では、translation unit内のPTWがflush後の古いメモリ応答をDrainRespで捨てられるように、PTWへの `ptw_mem_rvalid` は `mem_if.rvalid` を直接渡す。
ただし、通常のinstruction fetch応答とPTW応答を混ぜてはいけない。
現在はfetcher側で、最後に受理した命令側memory requestのownerを保持する。

```text
FetchMemOwnerInst:
  通常instruction fetchの応答としてfetch FIFOへ渡す

FetchMemOwnerPtw:
  PTWのPTE read応答としてtranslation unitへ渡す
```

control hazardでfetch状態を捨てた後に古いinstruction fetch応答が返ってきた場合は、PTWへ渡さず破棄する。
PTW requestが発行済みのままflushされた場合は、ownerをPtwとして残し、PTW内部のDrainRespで古い応答を捨てる。

## Translation Unit Boundary

CPU側からは、TLBやPTWを直接意識させない。

```systemverilog
module address_translation (
    input logic clk,
    input logic rst,

    input logic flush,      // cancel in-flight translation/PTW
    input logic tlb_flush,  // invalidate TLB entries

    input logic req_valid,
    output logic req_ready,
    input Addr req_va,
    input PrivMode req_priv_mode,
    input PmpAccessType req_access_type,
    input logic req_sum,
    input logic req_mxr,
    input UIntX satp,

    output logic rsp_valid,
    input logic rsp_ready,
    output Addr rsp_pa,
    output logic rsp_fault,
    output Sv39Fault rsp_fault_detail,

    output logic ptw_mem_valid,
    output Addr ptw_mem_addr,
    input logic ptw_mem_ready,
    input logic ptw_mem_rvalid,
    input logic ptw_mem_error,
    input logic [MEMBUS_DATA_WIDTH-1:0] ptw_mem_rdata
);
```

`flush` と `tlb_flush` は分ける。

```text
flush:
  branch/trap/control redirectで、進行中のtranslation要求だけを破棄する

tlb_flush:
  satp write / sfence.vmaで、TLB entryを全消去する
```

分岐や通常trapのたびにTLB entryを消すと、Linuxではcontrol flush数と同じ規模でITLBが無効化され、TLBとして機能しなくなる。

内部の基本構成:

```text
IDLE
  ├─ satp.MODE=0 Bare → RESPONSE
  ├─ TLB hit          → RESPONSE
  └─ TLB miss         → PTW_WAIT → REFILL → RESPONSE
```

miss中は要求を保持する。

```text
pending_va
pending_priv_mode
pending_access_type
pending_sum
pending_mxr
```

これにより、fetch側やLSU側の入力がstall中に変わっても、最初に受理した要求を最後まで処理できる。

PTW完了時のleaf情報は、次の `Refill` 状態までwrapper内で保持する。

```text
refill_pa
refill_leaf_pte
refill_leaf_level
refill_leaf_valid
```

理由:

```text
ptw_done / leaf_valid は1サイクルpulseになり得る
Refill状態でPTW出力を直接読むとTLBへ登録されない可能性がある
```

現在のTLBはleaf levelを保持するので、superpageもTLBへ登録する。

```text
leaf_level=0  4 KiB  → TLB refill
leaf_level=1  2 MiB  → TLB refill、VPN[2:1]でmatch
leaf_level=2  1 GiB  → TLB refill、VPN[2]でmatch
```

TLB lookupは新しいrequestを受理する `Idle && req_valid && Sv39 && !M-mode` の時だけ行う。
`PtwWait` / `Refill` / `Response` では再lookupしない。

## Naming

命令側:

```text
instruction_translation
  ├─ ITLB
  └─ PTW
```

データ側:

```text
data_translation
  ├─ DTLB
  └─ PTW
```

最初は命令側・データ側それぞれに専用PTWを持たせる。後で必要になったら共有PTWとarbiterへ移す。

```text
first step:
  instruction_translation + dedicated PTW

next:
  data_translation + dedicated PTW

later:
  ITLB miss ─┐
             ├─ PTW arbiter → shared PTW
  DTLB miss ─┘
```

## Demand Refill, Not Prefetch

現在のTLB方針は prefetch ではない。

```text
CPUが仮想アドレスAを要求
  ↓
TLB miss
  ↓
PTWでAを変換
  ↓
Aの変換結果をTLBへ登録
```

これは demand refill です。将来使うページを先読みして登録する仕組みではありません。

## Superpage TLB And Walk Cache

Sv39のページウォークは最大3段です。

```text
4 KiB page      level 2 → level 1 → level 0 leaf  最大3回PTE read
2 MiB superpage level 2 → level 1 leaf            最大2回PTE read
1 GiB superpage level 2 leaf                      最大1回PTE read
```

Hypervisorの二段変換はまだ対象外なので、現時点のMiNTs-CPUでは通常最大3回です。

現在のTLBは4KiB/2MiB/1GiB leafをrefillする。

次の改善候補:

```text
page-walk cache
  level 2やlevel 1のnon-leaf PTE結果を小さく保持する
  leaf TLB miss時でも、上位段PTE readを省く
```

優先順位は、`[PERF-ITLB]` の結果で決める。

```text
leaf_l1_2m / leaf_l2_1g が多いがhit率が上がらない
  superpage TLBのmatch幅やPA合成を確認する

leaf_l0_4k が多く、mem_req / miss が3に近い
  page-walk cacheを検討する

hit率が高いのにCPIが悪い
  fetch側のTLB hit fast pathを先に作る
```

## Next Steps

1. `tlb.sv` 単体テストを通す
2. `sv39_ptw.sv` に leaf PTE flags と leaf level 出力を追加
3. `rtl/mmu/address_translation.sv` の共通wrapperを追加
4. `rtl/mmu/instruction_translation.sv` を追加し、内部で共通wrapperを使う
5. `src/inst_fetcher.sv` の PTW 入口へ instruction_translation を挿入
6. `rtl/mmu/data_translation.sv` を追加し、LSU側へ展開
7. `sfence.vma` と `satp` write で TLB entry を全flush
8. performance counterに以下を追加

```text
itlb_lookup
itlb_hit
itlb_miss
itlb_miss_cycles
```

1〜5は完了。6はまだ未接続。7はfetch側で `translation_flush_fetch_value` として `satp` / `sfence.vma` の1cycle pulseを出し、`tlb_flush`へ接続済み。

## Validation Order

```text
1. tb/unit/tlb
2. small bare-mode boot
3. OpenSBI
4. Linux notrace baseline
5. Linux +PERF_SUMMARY 300M cycle comparison
```

現在確認済み:

```text
tb_tlb                    pass
tb_address_translation    pass
make build                pass
make test-output          pass
make test-os2-min-sv39    pass
```

Linux notrace Imageは、20M cycleの短いOpenSBI smokeで `+PERF_SUMMARY` まで完走確認済み。
初期の300M cycle Linux比較測定では、ITLB接続後にCPIが悪化し、primary ifetch stallが大きく増えた。
詳細は `docs/PERFORMANCE_COUNTERS.md` に記録する。

初回の `[PERF-ITLB]` では、`flush` がcontrol flushと同じ規模になり、さらに `miss_cycles` が非常に大きかった。
これは、分岐flushでTLB entryまで無効化していたこと、およびPTW待ちがcontrol redirectで頻繁にキャンセルされていたことを示す。
現在は `flush` と `tlb_flush` を分離済み。

その後の再測定では `flush=14` まで下がったが、`mem_req=9` / `mem_resp=8` のままPTW待ちが残った。
これに対して、fetcherにmemory response ownerを追加し、通常fetch応答とPTW応答を分離した。

その後、2MiB superpage leafをTLBへrefillできるようにし、Linux 300M測定ではITLB単体で改善が確認できた。

```text
baseline no TLB/cache:
  retired=43,361,299
  CPI=6.918

ITLB fixed superpage refill:
  retired=53,176,454
  CPI=5.641
  hit_rate_x1000=999
  miss=1877
  superpage_refill=1875
```

現在のI-cache込みの最新値は `docs/PERFORMANCE_COUNTERS.md` に記録する。

ITLB接続後にまず見る値:

```text
CPI
ifetch primary stall cycles
active ifetch cycles
itlb hit rate
itlb miss cycles
```
