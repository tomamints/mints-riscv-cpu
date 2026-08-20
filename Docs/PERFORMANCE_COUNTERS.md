# Performance Counters

Last updated: 2026-08-20

MiNTs-CPU exposes simulation-only performance counters through the
`+PERF_SUMMARY` Verilator plusarg. They are intended for comparing RTL changes
under the same boot image and cycle limit.

These counters are not currently exposed through a Linux ABI or RISC-V HPM CSR
interface.

## How To Run

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY \
  2>&1 | tee /tmp/perf-100m.log
```

Useful summary filter:

```bash
grep -aE '^\[PERF\] cycles|^\[PERF\] primary|^\[PERF\] active|^\[PERF\] events|^\[PERF-FETCH-STALL\]|^\[PERF-CONTROL\]|^\[PERF-BPRED\]|^\[PERF-BTB\]|^\[PERF-RAS\]' /tmp/perf-100m.log
```

## Main Counter Groups

| Prefix | Meaning |
|---|---|
| `[PERF] cycles` | total cycles, retired instructions, CPI, IPC |
| `[PERF] primary` | one primary no-commit reason per cycle |
| `[PERF] active` | all active stall reasons, counted with overlap |
| `[PERF] events` | architectural/event counts such as branches and loads |
| `[PERF-CONTROL]` | redirect source classification |
| `[PERF-BPRED]` | branch predictor accuracy |
| `[PERF-BTB]` | JALR BTB accuracy |
| `[PERF-JALR]` | JALR call/return/other classification |
| `[PERF-RAS]` | return-address stack accuracy |
| `[PERF-MEMU-*]` | LSU/memunit state and fixed-latency breakdown |
| `[PERF-DCACHE-*]` | D-cache, response, miss, and write policy counters |
| `[PERF-STOREBUF-*]` | store buffer occupancy, drain, and dependency counters |
| `[PERF-ITLB]`, `[PERF-DTLB]` | TLB and PTW behavior |

## Current Stable Checkpoint

Stable 100M-cycle result:

```text
[PERF] cycles=100000000 retired=41780831 cpi_x1000=2393 ipc_x1000=417
```

Stable configuration:

```text
DCACHE_LINE_COUNT=512
DCACHE_STORE_BUFFER_DEPTH=8
DCACHE_WRITE_BACK=0
```

## Recent Optimization Evidence

| Change | Main evidence |
|---|---|
| Branch/JAL/JALR early redirect | reduced frontend/control waste |
| 2-bit PHT + BTB + RAS | reduced control flushes and JALR misses |
| MEM translation-to-access fast path | reduced fixed LSU request latency |
| D-cache hit-load fast sideband | reduced response fixed latency |
| 512-line D-cache + 8-entry store buffer | improved load miss behavior |
| Fetch-side branch BTB + fetch fall-through | reduced taken-branch and fetch-block handoff overhead |
| Write-back experiment | reduced traffic, but did not beat stable write-through CPI |

Current frontend evidence:

```text
[PERF-FETCH-STALL] fifo_full=7320628 control_recovery=14156540 translation_issue=19680007 translation_req_wait=0 translation_rsp=22023 icache_req=2586028 icache_rsp=5765099 fault=0 no_request=0
[PERF-CONTROL] branch=1246862 jal=726042 jalr=127390 trap=1611 return=1679 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=5561110 hit=4314232 miss=1246878 hit_rate_x1000=775
[PERF-BTB] jalr=421644 hit=294253 miss=127391 hit_rate_x1000=697 entries=32
[PERF-RAS] return=352959 hit=275654 miss=77305 fallback_btb=131 hit_rate_x1000=780 depth=8
```

## Interpretation Notes

- `primary` counters partition no-commit cycles into one dominant reason.
- `active` counters intentionally overlap.
- Cache miss counts are not the same as CPU stall cycles.
- Whisper lockstep runtime is not a CPU performance metric.
- Performance numbers are Verilator simulation checkpoints, not FPGA or silicon
  frequency results.

## CPI Stack Direction

The current counter groups are intended to support CPI-stack summaries across
workloads:

```text
ideal scalar in-order CPI
+ branch/control
+ I-cache/fetch
+ D-cache/load
+ store path
+ TLB/PTW
+ memory arbitration
+ uncached/MMIO
+ other
= total measured CPI
```

This format keeps optimization decisions tied to measured stall sources rather
than raw event counts.
