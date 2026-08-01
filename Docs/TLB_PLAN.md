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

これらの `rtl/mmu/` ファイルはまだ `core.f` に入れていない。したがって、現在の Linux baseline には影響しない。

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
page size        4 KiB only
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

## Why This Is Not Connected Yet

translation unitは単体で確認済みだが、まだfetch/LSUの制御FSMへは接続していない。
次に接続する時点で、既存のfetch PTW制御を `instruction_translation` へ置き換える。

## Translation Unit Boundary

CPU側からは、TLBやPTWを直接意識させない。

```systemverilog
module address_translation (
    input logic clk,
    input logic rst,

    input logic flush,

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

現在のTLBは4 KiB page専用なので、superpageはTLBへ登録しない。

```text
leaf_level=0  4 KiB  → TLB refill
leaf_level=1  2 MiB  → そのアクセスにはPTW結果を使うが、TLB refillしない
leaf_level=2  1 GiB  → そのアクセスにはPTW結果を使うが、TLB refillしない
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

## Next Steps

1. `tlb.sv` 単体テストを通す
2. `sv39_ptw.sv` に leaf PTE flags と leaf level 出力を追加
3. `rtl/mmu/address_translation.sv` の共通wrapperを追加
4. `rtl/mmu/instruction_translation.sv` を追加し、内部で共通wrapperを使う
5. `src/inst_fetcher.sv` の PTW 入口へ instruction_translation を挿入
6. `rtl/mmu/data_translation.sv` を追加し、LSU側へ展開
7. `sfence.vma` と `satp` write で translation unit を全flush
8. performance counterに以下を追加

```text
itlb_lookup
itlb_hit
itlb_miss
itlb_miss_cycles
```

1〜4は完了。次は5から開始する。

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
```

ITLB接続後にまず見る値:

```text
CPI
ifetch primary stall cycles
active ifetch cycles
itlb hit rate
itlb miss cycles
```
