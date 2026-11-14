# Current Status

As of 2026-11-13, MiNTs-CPU boots OpenSBI v1.3.1, Linux 6.12 and BusyBox 1.36.1
on a physical DE0-CV, with an interactive UART shell and the normal hardware
clocksource. The M1 Mac build workflow and the smaller board profile are
specified in the [board guide](../fpga/de0-cv/soc/README.md).

## Validated targets

| Target | Configuration | End-to-end result |
|---|---|---|
| Verilator on Apple M1 through Docker | Legacy simulated platform, 128 MiB RAM | Linux boot and `BUSYBOX-TEST-PASS` |
| DE0-CV physical FPGA | 20 MHz, 64 MiB SDRAM, 100 Hz periodic Linux ticks | BusyBox shell, repeated UART commands, CPU/file/zero-data load, sleep and idle recovery |
| Whisper reference comparison | Historical simulation configurations | Over 61 million compared architectural instructions through BusyBox autotest; not rerun for the final board profile |

The standard kernel rebuild also embeds [MiNTs Life](../examples/life/README.md),
a static RV64IMAC/LP64 C application. Its UART demo, self-test and deterministic
benchmark checksums have passed on the board, with shell operation after exit.
Benchmark time is application wall time, not hardware CPI.

A shell prompt alone is not the board test criterion. Continued command
responses, timer interrupts and time progression were also checked.

## Configuration comparison

| Item | Plain Makefile defaults | Linux simulator rebuild profile | DE0-CV build defaults |
|---|---:|---:|---:|
| RAM | 128 MiB | 128 MiB | 64 MiB |
| I-cache | 4 KiB | 4 KiB | 1 KiB |
| D-cache | 4 KiB | 16 KiB | 1 KiB |
| Store buffer | 4 | 8 | 4 |
| ITLB / DTLB entries | 8 each | 8 each | 2 each |
| Branch prediction | Enabled | Enabled | Disabled |
| D-cache policy | Write-through | Write-through | Write-through |
| DTB timebase | 50 MHz | 50 MHz | 20 MHz |

These are selected profiles, not size limits. Caches use 32-byte lines. The
board cache data arrays use synchronous M10K RAM. The board also enables
read-only JTAG CPU snapshots. Its 100 Hz kernel setting changes interrupt
frequency, not CPU frequency or the `riscv_clocksource` timebase.

## Board GPIO

The board-only `SVCPU_BOARD_GPIO=1` build exposes a small MMIO peripheral at
`0x40000000` through Linux UIO. Switch/key inputs use two-stage synchronization;
applications can temporarily replace the diagnostic LED display. Fault bits
remain visible. The simulator's debug/exit window is retained in generic builds.

Physical tests passed GPIO register read/write self-test, LED ownership switching,
Life GPIO-mode generation/checksum and restoration on exit. Initial switch/key
readings were zero. Manual input transitions and optical LED observation were
not performed; native tests cover pause/resume, button reset and signal cleanup.
See [GPIO API](../examples/boardctl/README.md).

## VGA application display

The board build enables `SVCPU_BOARD_VGA=1`: an 80 × 30 text screen with
640 × 480 active pixels, driven from CLOCK_50 with a 25 MHz pixel enable.
The CPU/timer/SDRAM remain at 20 MHz. Double-buffered text RAM and font ROM
use nine additional M10K blocks. UART remains the Linux console.

Physical tests passed `vgactl self-test`, demo command acknowledgement, Life
four-generation checksum `401a90e3423e2d3c`, LED ownership restoration and
continued benchmark/shell operation using `riscv_clocksource`. The acknowledged
page count advanced from 0 to 9 through these display tests. No monitor image
was observed; command acknowledgements do not prove optical output.
See [VGA details](../fpga/de0-cv/vga/README.md).

## Physical implementation

| Metric | Validated DE0-CV build |
|---|---:|
| Device | Cyclone V 5CEBA4F23C7N |
| ALMs | 17,123 / 18,480 (93%) |
| Registers | 13,871 |
| RAM blocks | 64 / 308 |
| RAM bits | 230,052 / 3,153,920 |
| Pins checked | 80 |
| CPU / SDRAM controller / timer clock | 20 MHz |
| Worst setup slack | +1.960 ns |
| Estimated average / peak interconnect usage | 48% / 69% |
| Timing checks | Setup/hold/recovery/removal pass at all four corners |

This is a passing 20 MHz implementation, not an Fmax measurement. Rebuilt
artifacts need their own signoff. The loader writes volatile SRAM/SDRAM and
verifies all image words before releasing the CPU.

## Architecture and software boundaries

The CPU implements an RV64IMAC Linux boot path with M/S/U privilege modes,
Sv39 address translation, eight PMP entries, ACLINT, a PLIC-compatible controller
and an NS16550-compatible UART. Userspace is statically linked for RV64IMAC/LP64.

No F/D floating point, vector extension, SMP/cache coherence, complete RVA23
certification, persistent root filesystem or graphical board console is claimed.
Experimental write-back cache support is outside the validated board profile.

The 100 Hz board profile works with `riscv_clocksource`. Tested 250 Hz
configurations still lost responsiveness; long-duration stability remains
unverified. Historical simulator CPI figures
cannot be applied to the board's smaller caches and disabled predictor.
See [test status](TEST_STATUS.md) and [Linux baseline](LINUX_BASELINE.md).
