# MiNTs Life

A small Conway's Game of Life application for the MiNTs Linux UART shell.
It runs the same deterministic 32 × 16 toroidal world in two modes:

```sh
life --demo          # 40 generations, terminal animation
life --demo 10       # shorter demo
life --board 40     # GPIO-enabled board: switch/button control and generation LEDs
life --bench         # 100 generations, no display inside the measured loop
life --bench 1000    # longer run
life --self-test     # block and wraparound blinker checks
```

The demo uses ANSI clear/home sequences when stdout is a terminal. Redirected
output is plain text. It waits 200 ms after each generation in addition to
calculation/output time; it does not promise a fixed frame rate. Ctrl-C stops
the program without changing terminal input settings.

The 32 × 16 size is deliberately small enough for readable UART output.
Both modes start from the same fixed seed.

For board mode, SW0 pauses/resumes and KEY0 resets the world. See
[GPIO controls and prerequisites](../boardctl/README.md); the ordinary `--demo`
and `--bench` modes do not require GPIO.

## Benchmark meaning

The benchmark initializes a fixed xorshift32 seed (`0x4d494e54`), times only
the generation loop using `CLOCK_MONOTONIC`, then calculates a 64-bit FNV-1a
checksum over live/dead bytes in row-major order. Initial output, seed creation,
checksum calculation and final output are outside the timed loop.

The report contains elapsed wall time, cell updates and updates per second.
It includes any OS scheduling/interrupt time during that interval. It does not
claim hardware cycles, retired instructions, CPI, CoreMark or general CPU
performance. Use the same binary, input and environment for comparisons;
record compiler options and the CPU/cache/memory profile as well.

After 100 generations, the expected checksum is:

```text
Checksum: 9b6d74a5221ad510
```

## Build and install

The standard Linux kernel rebuild cross-compiles the application with the
RV64IMAC/LP64 musl toolchain (`-O2`, static linking) and embeds it as `/bin/life`:

```sh
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh kernel
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh image
```

The standalone ELF is `build/apps/life`. The complete clean `all` workflow also
includes it. Existing FPGA RTL is sufficient; no Quartus rebuild is needed
when adding only this userspace program. Reload the resulting Linux RAM image
using [the board boot procedure](../../fpga/de0-cv/soc/README.md).

For a standalone cross-build inside the prepared Linux container:

```sh
bash tools/build-life.sh
```

Native development tests require a C compiler and Python 3.8 or newer:

```sh
python3 tools/test-life.py
```

The test uses an independent Python model with modulo-indexed neighbors,
compares checksums after several generation counts, checks wraparound patterns,
and exercises demo output and invalid arguments. Host performance is not a
measurement of the FPGA CPU.

## Physical-board validation

On the documented DE0-CV 20 MHz configuration (1 KiB I/D caches, two-entry
ITLB/DTLB, predictor disabled, Linux 6.12 with normal clocksource and 100 Hz
periodic ticks), self-tests passed and checksums matched the native/Python
reference for one and 100 benchmark generations and four demo generations.
The shell remained responsive after the application exited.

One 100-generation run measured 0.748945750 seconds for 51,200 cell updates
(68,362 updates/s), with checksum `9b6d74a5221ad510`. This is a single application
measurement using the build script's `-O2` settings, not a statistical performance
study or a comparison against another CPU. A clean rebuild can change the
binary and elapsed time; the deterministic checksum should remain the same.
