# RTL Layout

Last updated: 2026-08-14

This document describes the current source layout and the intended direction for
future cleanup.

## Current Layout

```text
src/                 SystemVerilog RTL
tb/                  Verilator C++ harness and testbench code
tb/unit/             unit-level SystemVerilog testbenches
core/test/           bare-metal and regression test programs
platform/            boot ROM, payloads, DTB, and platform files
tools/               build and analysis helpers
tools/whisper_lockstep/
                     Whisper reference wrapper
third_party/patches/ third-party compatibility patches
Docs/                public project documentation
```

`src/` should contain RTL only. Simulation harnesses and fixture files should
live outside `src/`.

## Important RTL Files

| File | Role |
|---|---|
| `src/core.sv` | 5-stage pipeline integration |
| `src/inst_fetcher.sv` | frontend, ITLB, I-cache, branch prediction interface |
| `src/memunit.sv` | LSU, DTLB, PMP, D-cache request path |
| `src/sv39_ptw.sv` | Sv39 page table walker |
| `src/tlb.sv` | small TLB structure |
| `src/branch_predictor.sv` | PHT, BTB, and RAS-based prediction |
| `src/csrunit.sv` | privileged CSRs and trap/interrupt handling |
| `src/pmp_checker.sv` | physical memory protection checks |
| `src/mmio_controller.sv` | MMIO decode |
| `src/plic.sv` | minimal PLIC-compatible interrupt controller |
| `src/aclint_memory.sv` | MSWI/MTIMER |
| `src/uart_ns16550.sv` | minimal NS16550A-compatible UART |
| `src/top.sv` | SoC top-level integration |

## Build Lists

The Verilator build uses `core.f` as the RTL file list. Keep `core.f` explicit
so that RTL changes are reviewable.

The C++ Verilator harness is:

```text
tb/tb_verilator.cpp
```

## Future Direction

The current `src/` layout is stable enough for Linux and lockstep work. Larger
directory moves should wait until there is a clear payoff. If the RTL is split
later, use a staged structure such as:

```text
rtl/core/
rtl/frontend/
rtl/lsu/
rtl/mmu/
rtl/cache/
rtl/soc/
rtl/common/
```

Any future move should preserve the Linux and Whisper baselines at each step.
