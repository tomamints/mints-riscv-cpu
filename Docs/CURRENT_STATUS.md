# Current Status

This document is the current high-level status of **MiNTs-CPU**.

Last updated: 2026-08-12

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
| BTB | 32-entry JALR target BTB |
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

```text
Phase 8.3 JALR early redirect:
  [PERF] cycles=100000000 retired=33557400 cpi_x1000=2979 ipc_x1000=335
  [PERF] primary commit=33557400 no_commit=66442600 mem=23745865 muldiv=3254573 data_hazard=794093 ifetch=18691860 other=19956209
  [PERF-CONTROL] branch=1951066 jal=669757 jalr=411594 trap=1531 return=1577 satp=13 sfence=2000 other=0

Phase 9.1 static branch predictor:
  [PERF-BPRED] pred=4329566 hit=3093544 miss=1236022 hit_rate_x1000=714
  [PERF] cycles=100000000 retired=34725769 cpi_x1000=2879 ipc_x1000=347

Phase 9.2 2-bit PHT predictor:
  [PERF-BPRED] pred=4473131 hit=3803100 miss=670031 hit_rate_x1000=850
  [PERF] cycles=100000000 retired=35561702 cpi_x1000=2812 ipc_x1000=355
  Whisper BusyBox autotest pass

Phase 9.3 JALR BTB:
  [PERF-BTB] jalr=416164 hit=168874 miss=247290 hit_rate_x1000=405 entries=32
  [PERF] cycles=100000000 retired=36163117 cpi_x1000=2765 ipc_x1000=361
  Whisper BusyBox autotest pass

Phase 9.4 RAS:
  [PERF-JALR] call=35328 return=349378 other=32157
  [PERF-RAS] return=349378 hit=325546 miss=23832 fallback_btb=771 hit_rate_x1000=931 depth=8
  [PERF] cycles=100000000 retired=36690014 cpi_x1000=2725 ipc_x1000=366
  [PERF] primary commit=36690014 no_commit=63309986 mem=25359068 muldiv=3264316 data_hazard=804410 ifetch=14451685 other=19430507

Phase 10.1 MEM translation->access fast path:
  [PERF] cycles=100000000 retired=38038242 cpi_x1000=2628 ipc_x1000=380
  [PERF] primary commit=38038242 no_commit=61961758 mem=19229826 muldiv=3294097 data_hazard=751781 ifetch=16592212 other=22093842
  [PERF-MEMU-FIXED] translation_done=8454789 access_accept=2258666 response_done=6421060 split_accept=50351 split_response_done=25176

Phase 10.2 passive D-cache hit-load sideband:
  [PERF-DCACHE-FAST] hit_load=4986113
  [PERF-MEMU-FAST] hit_load=4986113
  [PERF-MEMU-FIXED] translation_done=8643157 access_accept=2264778 response_done=1567104 split_accept=50351 split_response_done=25176
  [PERF] cycles=100000000 retired=38719295 cpi_x1000=2582 ipc_x1000=387
  Whisper BusyBox autotest pass

Phase 10.3 store/write-through traffic instrumentation:
  [PERF-DCACHE-MIX] load_hit=... load_miss=... store_hit=... store_miss=...
  [PERF-STOREBUF-OCC] empty=... one=... two=... almost_full=... full=...
  [PERF-STOREBUF-DRAIN] urgent_active=... urgent_wait=... low_active=... low_wait=...
  [PERF-STOREBUF-COMBINE] candidate=... tail_word=... tail_disjoint=... any_word=... any_line=...
  Short +PERF_SUMMARY smoke passed
  DCACHE_STORE_BUFFER_DEPTH Make variable added for 4 vs 8 A/B testing
  DCACHE_LINE_COUNT Make variable added for 128 vs 256 A/B testing

Phase 10.4 D-cache capacity A/B:
  DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8
  [PERF-DCACHE] hit_rate_x1000=816 lines=512
  [PERF-DCACHE-MIX] load_miss=228196 store_miss=1398369
  [PERF-DSTALL] load_miss=2937174
  [PERF] cycles=100000000 retired=39534138 cpi_x1000=2529 ipc_x1000=395
  Stable Phase 10 configuration selected:
    DCACHE_LINE_COUNT=512
    DCACHE_STORE_BUFFER_DEPTH=8
    DCACHE_WRITE_BACK=0

Phase 10.5 experimental write-back D-cache:
  DCACHE_WRITE_BACK Make variable added
  Default remains write-through
  Initial write-back scope:
    store hit -> dirty cache line, no store buffer enqueue
    store miss -> no-write-allocate write-through
    dirty victim load miss -> writeback before refill
    dirty hit AMO -> writeback + invalidate before AMO bypass
  100M result after clean-flush skip/profiling:
    [PERF-DCACHE] mem_req=4126135 write_through=1395018 lines=512
    [PERF-DCACHE-WB] enabled=1 store_hit=1854144 evict=50650 words=202600 req_wait=440515
    [PERF-DCACHE-WB-FLUSH] clean=1007 dirty=1002 scan=513024 dirty_lines=3555 words=14220 req_wait=35727
    [PERF] cycles=100000000 retired=39508553 cpi_x1000=2531 ipc_x1000=395
  Conclusion:
    write-back reduces write traffic and arbiter pressure
    but does not beat the selected write-through stable configuration yet
    keep it as a research/experimental branch target
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
4. Keep write-back D-cache as an experimental path, not the stable baseline.
5. For the next mainline phase, measure the stable baseline first, then choose the next bottleneck.
6. Run Whisper lockstep after any frontend, LSU, cache, or privilege/MMU change.
```
