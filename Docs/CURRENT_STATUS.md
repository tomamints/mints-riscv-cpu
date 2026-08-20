# Current Status

Last updated: 2026-08-20

This document is the current high-level status of **MiNTs-CPU**.


## One-Line Status

MiNTs-CPU is now a Linux-capable RV64IMAC in-order CPU/SoC prototype with
Sv39, PMP, ACLINT, PLIC, NS16550A UART, ITLB/DTLB, I-cache, D-cache, store
buffer, performance counters, and Whisper lockstep validation through a
BusyBox autotest.

## End-To-End Checkpoint

The strongest validated path is:

```text
MiNTs-CPU RTL
  -> OpenSBI v1.3.1 fw_jump
  -> Linux 6.12.x
  -> initramfs
  -> rv64imac/lp64 static BusyBox
  -> /init autotest
  -> BUSYBOX-TEST-PASS
```

The autotest covers proc/sysfs/devtmpfs/tmpfs mount, `uname -a`, `ls /`,
`pwd`, tmpfs file write/read, and cleanup.

Recent lockstep checkpoint:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

This means the RTL and Whisper reference stayed synchronized through roughly
61.6M compared architectural instructions, including Linux boot, user-mode
execution, syscalls, timer/external interrupts, and BusyBox autotest commands.

## Architecture

| Item | Current state |
|---|---|
| XLEN | 64-bit |
| Claimed ISA | RV64IMAC |
| Privilege modes | M, S, U |
| Address translation | Sv39 |
| Page sizes | 4KiB, 2MiB, 1GiB leaves |
| PMP | 8 entries |
| Timer / software interrupt | ACLINT MSWI / MTIMER |
| External interrupt controller | PLIC-compatible minimal controller |
| UART | NS16550A-compatible minimal UART |
| Main memory | 128MiB RAM at `0x80000000` |
| Linux image address | `0x80200000` |
| DTB address | `0x87f00000` |
| UART base | `0x10000000` |
| PLIC base | `0x0c000000` |
| Debug MMIO | `0x40000000` |
| Timer frequency | 50MHz in DTB |

## Microarchitecture

Current design level:

```text
small in-order pipeline
  -> frontend with ITLB and I-cache
  -> backend with DTLB, D-cache, AMO path, store buffer
  -> single memory path arbitrated between I-side and D-side
```

Implemented performance structures:

| Block | Current state |
|---|---|
| ITLB | 8-entry fully associative, round-robin, Sv39 refill |
| DTLB | 8-entry fully associative, round-robin, Sv39 refill |
| I-cache | 4KiB, 128 lines, 32B line, direct-mapped |
| I-cache refill | 4 x 8B, critical-word-first, early restart |
| D-cache | 4KiB, 128 lines, 32B line, direct-mapped |
| D-cache policy | write-through, no-write-allocate |
| Store buffer | 4 entries |
| Store buffer behavior | background drain, unrelated cache-hit load bypass |
| Arbiter | distinguishes I-side, D-side high priority, D-side low priority drain |
| Control redirect | JAL, conditional branch, and JALR early redirect |
| Branch predictor | 128-entry 2-bit PHT, BTFNT fallback for cold entries |
| BTB | 32-entry BTB used for fetch-side conditional branch targets and JALR targets |
| RAS | 8-entry non-speculative return address stack |

Not yet implemented:

```text
speculative RAS recovery
larger BTB
write-back D-cache
non-blocking caches
store-to-load forwarding with byte merge
dual-port/banked RAM
SMP/cache coherence
FPGA timing closure
```

## Software Stack

Validated components:

| Component | Current state |
|---|---|
| OpenSBI | v1.3.1 `fw_jump` |
| Linux | 6.12.x RISC-V kernel image |
| BusyBox | static `rv64imac/lp64`, soft-float ABI |
| Initramfs modes | `cmdloop-ttyS0`, `autotest`, and bring-up variants |
| Lockstep reference | Tenstorrent Whisper integration |

The important ABI constraint is that userland must be built for
`rv64imac/lp64` without F/D instructions. Prebuilt riscv64 Linux userland
often uses a double-float ABI and is not suitable for this CPU configuration.

## Verification Status

Passed categories:

```text
riscv-tests RV32/RV64 ui/um/ua/uc/mi/si -p suites
custom MMIO/debug tests
UART polling/input/interrupt tests
PLIC M-mode and S-mode interrupt tests
ACLINT MSWI/MTIMER tests
PMP load/store/fetch protection tests
Sv39 data/fetch/page-fault/permission tests
OpenSBI platform boot
Linux kernel boot to /init
BusyBox autotest
Whisper lockstep to BUSYBOX-TEST-PASS
```

Recent correctness bugs fixed during Linux/lockstep bring-up:

```text
UART THRE interrupt not cleared/reissued correctly
PLIC/CSR SEIP writable-bit latch issue
sstatus SPIE/SIE return behavior
SEPC write mask
instruction fetch STVAL using block base instead of architectural fault PC
lockstep non-retiring exception synchronization
lockstep MTIMER/SEIP one-shot injection
WFI interrupt EPC mismatch against Whisper
```

## Performance Status

The CPU is no longer in the pure bring-up phase. It is now in the
measure-and-optimize phase.

Historical 300M-cycle Linux measurements:

| Stage | Retired | CPI | IPC |
|---|---:|---:|---:|
| No TLB/cache baseline | 43,361,299 | 6.918 | 0.144 |
| ITLB superpage refill fixed | 53,176,454 | 5.641 | 0.177 |
| I-cache 4KiB 32B early restart | 56,871,866 | 5.275 | 0.189 |
| ITLB + I-cache + DTLB | 72,705,508 | 4.126 | 0.242 |
| D-cache 4KiB write-through | 72,689,380 | 4.127 | 0.242 |
| Store buffer initial | 72,632,625 | 4.130 | 0.242 |

Recent 100M-cycle checkpoints:

| Phase | Main change | Retired | CPI | IPC | Correctness |
|---|---|---:|---:|---:|---|
| 8.3 | JALR early redirect | 33,557,400 | 2.979 | 0.335 | Linux run |
| 9.1 | Static branch predictor | 34,725,769 | 2.879 | 0.347 | Linux run |
| 9.2 | 2-bit PHT predictor | 35,561,702 | 2.812 | 0.355 | Whisper pass |
| 9.3 | JALR BTB | 36,163,117 | 2.765 | 0.361 | Whisper pass |
| 9.4 | RAS | 36,690,014 | 2.725 | 0.366 | Linux run |
| 10.1 | MEM translation->access fast path | 38,038,242 | 2.628 | 0.380 | Linux run |
| 10.2 | D-cache hit-load fast sideband | 38,719,295 | 2.582 | 0.387 | Whisper pass |
| 10.4 | 512-line D-cache + 8-entry store buffer | 39,534,138 | 2.529 | 0.395 | Stable |
| 10.5 | Experimental write-back D-cache | 39,508,553 | 2.531 | 0.395 | Experimental |
| 11.1 | Fetch-side conditional branch BTB | 40,260,939 | 2.483 | 0.402 | rv64ui pass |

Recent improvement summary:

| Range | Main effect |
|---|---|
| Phase 8.3 -> 9.4 | Control speculation reduced frontend/control waste: early redirect, PHT, BTB, and RAS moved CPI from 2.979 to 2.725. |
| Phase 9.4 -> 10.2 | MEM/LSU fixed latency was reduced: translation-to-access bypass and D-cache hit-load sideband moved CPI from 2.725 to 2.582. |
| Phase 10.2 -> 10.4 | D-cache capacity and store buffer depth improved load-miss behavior, reaching the current stable CPI 2.529 point. |
| Phase 10.5 | Write-back reduced write traffic and arbiter pressure, but did not beat the selected write-through stable point. |
| Phase 11.1 | Fetch-side conditional branch BTB removed about one cycle per trained loop-back branch in a common assembly benchmark and improved the Linux 100M checkpoint from CPI 2.529 to 2.483. |

Key evidence by phase:

| Phase | Evidence |
|---|---|
| 9.1 | `[PERF-BPRED] pred=4329566 hit=3093544 miss=1236022 hit_rate_x1000=714` |
| 9.2 | `[PERF-BPRED] pred=4473131 hit=3803100 miss=670031 hit_rate_x1000=850` |
| 9.3 | `[PERF-BTB] jalr=416164 hit=168874 miss=247290 hit_rate_x1000=405 entries=32` |
| 9.4 | `[PERF-RAS] return=349378 hit=325546 miss=23832 fallback_btb=771 hit_rate_x1000=931 depth=8` |
| 10.1 | `[PERF-MEMU-FIXED] translation_done=8454789 access_accept=2258666 response_done=6421060` |
| 10.2 | `[PERF-DCACHE-FAST] hit_load=4986113`, `response_done=1567104` |
| 10.4 | `[PERF-DCACHE-MIX] load_miss=228196 store_miss=1398369`, `[PERF-DSTALL] load_miss=2937174` |
| 10.5 | `[PERF-DCACHE-WB] enabled=1 store_hit=1854144 evict=50650 words=202600 req_wait=440515` |
| 11.1 | `[PERF-BPRED] pred=5292133 hit=4463782 miss=828351 hit_rate_x1000=843`, `[PERF] retired=40260939 cpi_x1000=2483 ipc_x1000=402` |

Current stable Phase 10 configuration:

```text
DCACHE_LINE_COUNT=512
DCACHE_STORE_BUFFER_DEPTH=8
DCACHE_WRITE_BACK=0
```

Current representative checkpoint with fetch-side conditional branch BTB:

```text
[PERF] cycles=100000000 retired=40260939 cpi_x1000=2483 ipc_x1000=402
```

The previous stable write-through checkpoint was:

```text
[PERF] cycles=100000000 retired=39534138 cpi_x1000=2529 ipc_x1000=395
```

The fetch-side BTB change also required `fence.i` to invalidate frontend
prediction state. `rv64ui-p-fence_i` and the full `rv64ui-p` suite pass after
that fix.

See [FRONTEND_BRANCH_BTB.md](FRONTEND_BRANCH_BTB.md) for the benchmark and
correctness details.

Experimental write-back conclusion:

```text
write-back reduces write traffic and arbiter pressure,
but does not beat the selected write-through stable configuration yet.
Keep it as a research/experimental branch target.
```

Current bottleneck view:

```text
large:
  MEM-side translation/access/response latency
  control recovery
  D-cache misses and uncached accesses

medium:
  I-cache demand miss
  data hazards

small:
  TLB miss PTW time
  store buffer full stall
```

Next performance work should be driven by measured stall counters, not by
adding features blindly.

## Current Development Direction

Recommended next steps:

```text
1. Keep the BusyBox lockstep PASS as the correctness gate.
2. Keep using 100M-cycle +PERF_SUMMARY runs for iteration.
3. Treat Phase 10 stable configuration as complete:
   `DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=0`.
4. Treat fetch-side conditional branch BTB as the current mainline frontend
   improvement, with `fence.i` invalidating branch prediction state.
5. Keep write-back D-cache as an experimental path, not the stable baseline.
6. For the next mainline phase, measure the stable baseline first, then choose the next bottleneck.
7. Run Whisper lockstep after any frontend, LSU, cache, or privilege/MMU change.
```
