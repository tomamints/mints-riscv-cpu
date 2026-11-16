# MiNTs-CPU

**MiNTs-CPU is an experimental RV64IMAC RISC-V CPU and SoC written in SystemVerilog.**
It implements an in-order CPU with M/S/U privilege modes, Sv39 virtual memory,
PMP, instruction and data caches, a store buffer, branch prediction, interrupt
controllers and a UART. It builds on the
[cpu.kanataso.net teaching CPU material](https://cpu.kanataso.net/).

The project boots OpenSBI, Linux 6.12 and BusyBox in Verilator. It also runs
Linux with an interactive UART shell on a physical DE0-CV FPGA.

## Architecture

This conceptual diagram shows the simulator SoC and shared CPU architecture.
Buses, handshakes and arbitration are simplified. The diagram uses plain
Makefile defaults; the Linux simulation build uses a 16 KiB D-cache and an
8-entry store buffer instead of the default 4 KiB and 4 entries.

![MiNTs-CPU architecture: Verilator simulator SoC](Docs/images/architecture_simulation.svg)

The FPGA build uses the same CPU RTL with a smaller configuration and adds
board-specific memory and I/O. See the [FPGA architecture diagram](Docs/images/architecture_fpga.svg)
and [configuration comparison](Docs/CURRENT_STATUS.md#configuration-comparison).
Both diagrams can be regenerated with `python3 tools/draw-architecture.py`.
For source organization, see [RTL layout](Docs/RTL_LAYOUT.md).

## Verification

- **Linux simulation:** Verilator boots OpenSBI, Linux and BusyBox through
  `BUSYBOX-TEST-PASS`.
- **Architectural comparison:** historical Whisper lockstep runs compared over
  61 million committed instructions through the BusyBox autotest. This was a
  simulation configuration, not the final FPGA profile.
- **DE0-CV hardware:** Linux and BusyBox run at 20 MHz with 64 MiB SDRAM;
  UART interaction, file operations, CPU load and sleep/resume were exercised.

These are prototype results, not a claim of complete RISC-V certification or
production readiness. See [verification results and limitations](Docs/TEST_STATUS.md).

## Run in Verilator

With Docker Desktop running on Apple Silicon:

```sh
bash tools/rebuild-linux.sh all
bash tools/run-linux.sh
```

The first command builds the required artifacts; the second runs the simulation.
See [clean rebuild and dependencies](Docs/REBUILD_FROM_CLEAN.md).

## FPGA implementation

The DE0-CV profile uses 1 KiB instruction and data caches, two entries per TLB,
and disabled branch prediction. Its physical implementation passed timing at
20 MHz and used 17,269 / 18,480 ALMs. VGA command acknowledgement and microSD
file read/write were exercised; VGA monitor output and SD boot remain unverified.

[**DE0-CV Linux guide / 実機起動ガイド →**](fpga/de0-cv/soc/README.md)

Additional details: [current status and profile comparison](Docs/CURRENT_STATUS.md),
[MiNTs Life](examples/life/README.md), [GPIO](examples/boardctl/README.md),
[VGA](fpga/de0-cv/vga/README.md), and [microSD](fpga/de0-cv/sd/README.md).

## Documentation and license

- [Documentation index](Docs/README.md)
- [Linux setup](Docs/LINUX_SETUP.md) and [clean rebuild](Docs/REBUILD_FROM_CLEAN.md)
- [Performance counters](Docs/PERFORMANCE_COUNTERS.md) and [simulation baseline](Docs/LINUX_BASELINE.md)
- [BSD 3-Clause license](LICENSE) and [copyright / third-party notices](NOTICE)

Copyright (c) 2026, MiNTs Co., Ltd. (MiNTs株式会社). The project's original
contributions are available under the [BSD 3-Clause license](LICENSE), except
where a file or component specifies otherwise. Textbook-derived portions retain
Kanata Abe's copyright notice and BSD 3-Clause terms.
`tools/prepare-board-linux.py` remains GPL-2.0-only; external dependencies and
other third-party material retain their respective licenses. See [NOTICE](NOTICE).

[Tenstorrent Whisper](https://github.com/tenstorrent/whisper) is an optional
architectural reference licensed under Apache 2.0. External source trees retain
their own licenses. Proprietary Quartus installers, build outputs and local
development records are not distributed in this repository.
