# Roadmap

Last updated: 2026-08-20

This roadmap describes the public development direction of MiNTs-CPU.

## Current Stable Point

MiNTs-CPU is currently a Linux-capable RV64IMAC in-order CPU/SoC with:

- M/S/U privilege
- Sv39 MMU with ITLB, DTLB, and shared PTW
- PMP checks on fetch, data, and PTW reads
- ACLINT, PLIC-compatible interrupt controller, and NS16550A UART
- I-cache, D-cache, and store buffer
- forwarding and early control redirect
- 2-bit branch predictor, fetch-side conditional branch BTB, JALR BTB, and RAS
- Whisper lockstep through BusyBox autotest

Stable performance configuration:

```text
DCACHE_LINE_COUNT=512
DCACHE_STORE_BUFFER_DEPTH=8
DCACHE_WRITE_BACK=0
```

Representative stable checkpoint:

```text
100M cycles, CPI ~= 2.393, IPC ~= 0.417
```

## Completed Milestones

| Area | Status |
|---|---|
| RV64IMAC execution | basic tests and Linux path pass |
| privilege and traps | M/S/U, delegation, `mret`, `sret` |
| virtual memory | Sv39 with ITLB/DTLB/PTW |
| protection | PMP for fetch/data/PTW physical accesses |
| interrupts | ACLINT timer/software and PLIC external interrupts |
| Linux | OpenSBI -> Linux 6.12 -> BusyBox autotest |
| lockstep | Whisper architectural comparison to BusyBox PASS |
| frontend performance | early redirect, PHT, fetch-side branch BTB, JALR BTB, RAS |
| LSU performance | translation-to-access and hit-load fast paths |
| cache sizing | stable 512-line D-cache and 8-entry store buffer |

## Next Work

### 1. Documentation and Release Hygiene

- keep README and Docs fully English
- keep public documents reader-oriented, not chat/report oriented
- document stable commands and known-good configurations
- keep third-party Whisper changes as a small patch

### 2. Benchmarking and Reference Comparisons

- add controlled microbenchmarks before making cross-core claims
- keep the Rocket/MiNTs common assembly loop as a frontend regression test
- use CPI-stack style summaries instead of a single CPI number
- keep external core comparisons tied to reproducible workloads and settings
- separate simulation CPI from FPGA frequency and implementation cost

### 3. Memory System

- continue write-through stable baseline maintenance
- profile write-back mode separately
- investigate PTW/D-cache coherence before making write-back stable
- consider store-buffer combining or larger/better store drain policy

### 4. Verification

- keep Whisper lockstep as the main correctness gate
- keep `rv64ui-p-fence_i` in the fast regression path after frontend predictor
  changes
- add smaller deterministic regression tests for cache and LSU corner cases
- preserve BusyBox autotest as the end-to-end Linux gate

### 5. Benchmarks

- add CoreMark or Embench once correctness remains stable
- keep boot-window performance counters for microarchitectural A/B tests
- separate simulation CPI from FPGA frequency results

### 6. FPGA Bring-up

- synthesize the current stable configuration
- check timing for DTLB/D-cache/branch-predictor paths
- add FPGA-specific UART/clock/reset constraints
- report Fmax separately from simulation CPI

## Not Currently Claimed

- SMP or cache coherence
- write-back D-cache as the stable baseline
- floating point
- full RVA23 compliance
- FPGA timing closure
