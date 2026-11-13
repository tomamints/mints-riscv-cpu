# MiNTs-CPU

**A SystemVerilog RV64IMAC RISC-V CPU/SoC that boots Linux on a DE0-CV FPGA.**

MiNTs-CPU runs OpenSBI, Linux 6.12 and a static BusyBox userspace on the
Terasic DE0-CV, with an interactive shell over a physical UART. The validated
board configuration runs at **20 MHz with 64 MiB SDRAM**. The build workflow
was exercised on an **Apple M1 Mac**, using Docker for Linux and Quartus builds
and native macOS tools for USB-Blaster programming.

The project builds on the [cpu.kanataso.net teaching CPU material](https://cpu.kanataso.net/).
It includes M/S/U privilege modes, Sv39 virtual memory, PMP, instruction/data
caches, interrupt controllers, a custom SDRAM controller, and a verified JTAG
RAM loader. This is a prototype with a defined validation scope, not a
certified RISC-V implementation or a general-purpose Linux distribution.

**Start here:** [DE0-CV Linux guide / 実機起動ガイド](fpga/de0-cv/soc/README.md)
 · [Current status](Docs/CURRENT_STATUS.md)
 · [Documentation index](Docs/README.md)

## What runs

```text
DE0-CV FPGA
  → MiNTs RV64IMAC CPU + 64 MiB SDRAM
  → OpenSBI v1.3.1
  → Linux 6.12
  → BusyBox 1.36.1 initramfs
  → interactive UART shell
```

Physical-board checks cover continued UART commands, file creation/readback/
removal, a CPU loop, 1 MiB of zero-data processing, sleep and response after
an idle interval. The kernel uses the normal `riscv_clocksource`, with 100 Hz
periodic scheduler ticks. The CPU and hardware timer remain at 20 MHz;
there is no `clocksource=jiffies` override.

The FPGA implementation uses **17,049 / 18,480 ALMs (92%)** and passes
setup, hold, recovery and removal checks at all four timing corners at
20 MHz. Worst setup slack is **+3.750 ns**. This establishes the tested
20 MHz operating point, not a measured maximum frequency.

Verilator also boots Linux through `BUSYBOX-TEST-PASS`. Separate historical
Whisper lockstep runs compared over 61 million architectural instructions
through that autotest. Those results belong to their simulation configuration;
lockstep was not rerun for the final FPGA configuration.
See [test scope and limitations](Docs/TEST_STATUS.md).

## Simulator and FPGA configurations

These are selected operating profiles, not maximum supported capacities.

| Parameter | Linux simulator rebuild profile | Validated DE0-CV profile |
|---|---:|---:|
| RAM | 128 MiB simulated RAM | 64 MiB physical SDRAM |
| I-cache | 4 KiB | 1 KiB |
| D-cache | 16 KiB | 1 KiB |
| Cache line | 32 B | 32 B |
| Store buffer | 8 entries | 4 entries |
| ITLB / DTLB | 8 entries each | 2 entries each |
| Branch prediction | Enabled | Disabled |
| D-cache policy | Write-through | Write-through |
| Hardware timebase in DTB | 50 MHz | 20 MHz |
| Linux entry point | BusyBox autotest | Interactive BusyBox shell |

The simulator profile is selected by `tools/rebuild-linux.sh`; plain Makefile
defaults differ (4 KiB D-cache and a four-entry store buffer). The smaller
FPGA profile fits the board's logic and routing budget. No controlled benchmark
yet quantifies the performance difference between these profiles. Simulated
CPI, simulator wall time and physical FPGA frequency are different quantities.

## Build and run

### Linux in Verilator

With Docker Desktop running on Apple Silicon:

```sh
bash tools/rebuild-linux.sh all
bash tools/run-linux.sh
```

The first command builds dependencies and boot artifacts. The second runs the
simulator; success is `BUSYBOX-TEST-PASS`. See
[rebuilding and dependencies](Docs/REBUILD_FROM_CLEAN.md).

### Linux on DE0-CV

After installing the Quartus container and native USB-Blaster tools as described
in the [board guide](fpga/de0-cv/soc/README.md):

```sh
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh all
STAGE=asm bash tools/build-de0cv-soc.sh
bash tools/build-de0cv-jtag-load.sh
```

Connect the board's USB-Blaster USB-B port and a separate 3.3 V USB-UART
adapter. JP1-8 → adapter RXD, JP1-10 → adapter TXD, JP1-12 → GND. Open the
UART terminal at 115200 8N1, without flow control, before starting the CPU.

```sh
bash tools/program-de0cv-soc.sh
local/fpga-tools/bin/de0cv-jtag-load load-run build/platform/de0cv64/opensbi_ram.hex
```

Programming configures **volatile SRAM only**. The loader clears SDRAM,
writes the image, reads back every image word, and starts the CPU only after
verification succeeds. Power-off loses both FPGA configuration and RAM data.

## A userspace application

The standard Linux rebuild also embeds [MiNTs Life](examples/life/README.md), a
standalone C program cross-compiled for RV64IMAC/LP64. From the Linux shell:

```sh
life --demo 40
life --bench 100
```

Both modes have been exercised on the physical board, with checksum validation
and continued shell operation after exit. The demo animates a 32 × 16 Game of
Life world over UART. Benchmark mode runs
without display in the timed loop and reports elapsed time plus a deterministic
checksum. It is a specific application workload, not a CoreMark score or CPI
measurement.

## Linux-to-board GPIO

The board exposes its ten switches, four user buttons and application LED
controls through a small MMIO register and Linux UIO. From the Linux shell:

```sh
boardctl status
boardctl leds 0x155
boardctl diagnostics
life --board 40
```

Life's board mode uses SW0 to pause/resume, KEY0 to reset the world, and LEDs
to display the generation. The normal diagnostic display is restored on exit;
sticky fault indicators remain visible in application mode.

Physical checks verified register readback, a four-generation GPIO-mode run,
its checksum and restoration of LED ownership. Pause/reset input transitions
were exercised in the native model; manual switch transitions and optical LED
observation are separate checks. See [GPIO interface and controls](examples/boardctl/README.md).

## Architecture and sources

| Location | Contents |
|---|---|
| `src/` | CPU pipeline, CSRs/PMP, execution units, simulation SoC/peripherals |
| `rtl/cache/`, `rtl/mmu/` | Cache arrays/controllers and translation logic |
| `rtl/bus/`, `rtl/peripheral/` | SDRAM bus adapter and physical 16550 UART integration |
| `fpga/de0-cv/` | Board tops, PLL, SDRAM controller, UART PHY, JTAG loader and RAM primitive |
| `platform/` | Boot ROM, device trees and Linux configuration fragments |
| `tb/`, `core/test/` | Simulation harnesses, unit tests and bare-metal programs |
| `tools/` | Rebuild, programming, regression and analysis tools |

See [RTL layout](Docs/RTL_LAYOUT.md) for exact source paths.

## Scope

- RV64IMAC, M/S/U privilege, Sv39, eight PMP entries, ACLINT and PLIC-compatible interrupts.
- Static userspace must use RV64IMAC / LP64; prebuilt floating-point ABI binaries are unsuitable.
- F/D, vector execution, SMP/cache coherence and full RVA23 compliance are not claimed.
- The root filesystem and `/tmp` are RAM-based; persistent storage, networking and a graphical console are not part of the validated board configuration.
- Long-duration stability, 250 Hz board operation and higher FPGA frequencies are not established by the current tests.
- The board uses a write-through D-cache. Experimental write-back support is not the validated baseline.

## Documentation and attribution

- [Current status and profile comparison](Docs/CURRENT_STATUS.md)
- [Verification results and boundaries](Docs/TEST_STATUS.md)
- [Linux setup](Docs/LINUX_SETUP.md) and [clean rebuild](Docs/REBUILD_FROM_CLEAN.md)
- [Performance counters](Docs/PERFORMANCE_COUNTERS.md) and [historical simulation baseline](Docs/LINUX_BASELINE.md)
- [Complete documentation index](Docs/README.md)
- [Third-party notices](NOTICE)

[Tenstorrent Whisper](https://github.com/tenstorrent/whisper) is an optional
architectural reference for simulation lockstep and is licensed under Apache 2.0.
External source trees retain their own licenses. Proprietary Quartus installers,
build outputs and local development records are not distributed in this repository.
