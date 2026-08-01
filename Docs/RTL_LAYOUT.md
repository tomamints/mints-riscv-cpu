# RTL Layout Plan

この文書は、MiNTs-CPU のRTLを今後TLB、cache、branch predictor、性能カウンタへ拡張するための配置方針です。

## Policy

現時点では、既存の `src/` RTLを一気に移動しません。

理由:

```text
src/ と core.f は現在のLinux baselineの一部
大移動すると差分が大きくなり、Linux regression時に原因を追いにくい
TLB/cache追加前にbaselineを固定したい
```

したがって、移行は次の順で進めます。

```text
1. rtl/ の置き場だけ作る
2. 新規モジュールは rtl/ に追加する
3. wrapperはpass-throughから始める
4. Linux baselineが通るたびに小さくcommitする
5. baseline固定後に既存srcを段階的に移す
```

## Target Directory Structure

```text
rtl/
  core/
    frontend/
    execute/
    lsu/
    csr/
    pipeline/
    perf/
  mmu/
  cache/
  bus/
  peripheral/
  soc/
  common/
```

役割:

```text
rtl/core
  pipeline本体、frontend、execute、LSU、CSR、性能観測周辺

rtl/mmu
  Sv39 PTW、ITLB、DTLB、共通TLB、PMP

rtl/cache
  I-cache、D-cache、tag array、refill unit

rtl/bus
  membus interface、address decode、arbiter

rtl/peripheral
  UART、PLIC、ACLINT、DMAなどのSoC peripheral

rtl/soc
  top、memory map、SoC統合

rtl/common
  fifo、utility、package、共通typedef
```

## Current Source Mapping

現在の `src/` から将来の `rtl/` への対応:

```text
src/core.sv                    -> rtl/core/core.sv
src/inst_fetcher.sv            -> rtl/core/frontend/fetch.sv
src/inst_decoder.sv            -> rtl/core/pipeline/decode.sv
src/alu.sv                     -> rtl/core/execute/alu.sv
src/brunit.sv                  -> rtl/core/execute/brunit.sv
src/muldivunit.sv              -> rtl/core/execute/muldivunit.sv
src/amounit.sv                 -> rtl/core/execute/amounit.sv
src/memunit.sv                 -> rtl/core/lsu/memunit.sv
src/csrunit.sv                 -> rtl/core/csr/csrunit.sv
src/core.sv perf counters      -> rtl/core/perf/perf_counter.sv
src/pmp_checker.sv             -> rtl/mmu/pmp_checker.sv
src/sv39_ptw.sv                -> rtl/mmu/sv39_ptw.sv
src/membus_if.sv               -> rtl/bus/membus_if.sv
src/membus_arbiter_cpu_prio.sv -> rtl/bus/membus_arbiter_cpu_prio.sv
src/ram_arbiter.sv             -> rtl/bus/ram_arbiter.sv
src/uart_ns16550.sv            -> rtl/peripheral/uart_ns16550.sv
src/plic.sv                    -> rtl/peripheral/plic.sv
src/aclint_memory.sv           -> rtl/peripheral/aclint_memory.sv
src/dma.sv                     -> rtl/peripheral/dma.sv
src/mmio_controller.sv         -> rtl/soc/mmio_controller.sv
src/memory.sv                  -> rtl/soc/memory.sv
src/top.sv                     -> rtl/soc/top.sv
src/fifo.sv                    -> rtl/common/fifo.sv
src/util.sv                    -> rtl/common/util.sv
src/inst_gen_pkg.sv            -> rtl/common/inst_gen_pkg.sv
```

## Wrapper Boundaries

性能機能はpipelineへ直接埋め込まず、wrapper境界を作ります。

Frontend:

```text
PC generation
-> branch predictor wrapper
-> ITLB wrapper
-> I-cache wrapper
-> fetch buffer
-> decode
```

LSU:

```text
load/store request
-> DTLB wrapper
-> D-cache wrapper
-> memory / MMIO bus
```

Perf:

```text
frontend / execute / LSU / CSR / bus
-> perf observation signals
-> perf counters
-> Verilator summary or future MMIO/CSR readout
```

perfはpipelineの制御経路に入れず、横から観測します。

現在:

```text
src/core.sv 内で直接カウント
+PERF_SUMMARY でVerilator final時に表示
```

将来:

```text
rtl/core/perf/perf_counter.sv
perf_enable / perf_clear
perf_ctrl MMIO or CSR
```

最初のwrapperはpass-throughにします。

```text
branch predictor:
  predict not-taken / next PC = PC + instruction length

ITLB/DTLB:
  miss固定、既存PTWへ流す

I-cache/D-cache:
  cacheなし、既存memory/busへ流す
```

この形にすると、Linux baselineを壊さずに中身だけ差し替えられます。

## Filelist Strategy

現在のビルドは `core.f` が `src/` を列挙しています。

移行中は、次のどちらかで進めます。

```text
Option A:
  core.f に src/ と rtl/ の両方を明示列挙する

Option B:
  core.f から include filelist を読む構成へ分ける
```

推奨はOption Bです。

```text
filelists/common.f
filelists/core.f
filelists/mmu.f
filelists/cache.f
filelists/peripheral.f
filelists/soc.f
```

ただし、これはbaseline固定後に行います。今は `core.f` を維持します。

## Next Step

Phase 0では、`rtl/` へ実装を移さず、Linux baselineを固定します。

Phase 1でTLBを追加するとき、最初に作る新規ファイル:

```text
rtl/mmu/tlb.sv
rtl/mmu/itlb.sv
rtl/mmu/dtlb.sv
```

この時点で `core.f` へ新規ファイルだけ追加します。既存 `src/sv39_ptw.sv` は、TLB miss時に呼ぶ既存PTWとして残します。
