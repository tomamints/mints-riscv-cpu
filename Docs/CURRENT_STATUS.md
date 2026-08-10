# Current Status

This document is the current high-level status of **MiNTs-CPU**.

Last updated: 2026-08-11

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

Not yet implemented:

```text
branch predictor
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

Recent 100M-cycle run with additional stall counters:

```text
[PERF] cycles=100000000 retired=34025923 cpi_x1000=2938 ipc_x1000=340
[PERF-MEMU-STALL] translation=4238618 access_ready=12605077 response=10749236 split_ready=68123 split_response=35204 discard=0 fault=0
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
3. Reduce MEM-side fixed latency, especially DTLB-hit/memunit fast path.
4. Then move branch resolution/prediction forward.
5. Revisit D-cache structure only after stall counters show capacity/conflict pressure.
```
