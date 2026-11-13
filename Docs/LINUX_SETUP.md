# Linux Setup

MiNTs-CPU has two Linux targets. Both use OpenSBI v1.3.1, Linux 6.12 and a
statically linked BusyBox 1.36.1 initramfs for RV64IMAC / LP64. Prebuilt
riscv64 floating-point ABI userspace is not suitable for this CPU.

## Choose the platform

| Item | `legacy` (default) | `de0cv64` |
|---|---|---|
| Execution target | Verilator | Physical DE0-CV |
| RAM | 128 MiB at `0x80000000` | 64 MiB at `0x80000000` |
| Linux address | `0x80200000` | `0x80200000` |
| DTB load address | `0x87f00000` | `0x83f00000` |
| DTS | `platform/riscv_cpu.dts` | `platform/riscv_cpu_de0cv64.dts` |
| DTB hardware timebase | 50 MHz | 20 MHz |
| Default init | BusyBox autotest | Interactive BusyBox shell |
| Kernel fragments | `linux_minbringup.fragment` | Minimum fragment plus `linux_de0cv.fragment` |
| Generated platform directory | `build/platform/` | `build/platform/de0cv64/` |

The board kernel uses 100 Hz periodic scheduler ticks, with NO_HZ_IDLE and
HIGH_RES_TIMERS disabled, while retaining `riscv_clocksource`. The hardware
counter and CPU both run at 20 MHz. The board DTS includes explicit ISA base
and extension properties for Linux configurations without deprecated ISA-string
fallback. Do not substitute the legacy DTS or kernel for the board defaults.

## Build and run in Verilator

With Docker Desktop running, execute from the repository root:

```sh
bash tools/rebuild-linux.sh all
bash tools/run-linux.sh
```

The build wrapper prepares dependencies and a Linux executable simulator.
The run wrapper executes it in Docker; no FPGA is required. Expected result:

```text
BUSYBOX-TEST-BEGIN
...
BUSYBOX-TEST-PASS
```

The autotest ends in a sleep loop, not an interactive shell. The wrapper uses
a 300-million-cycle limit. Use `OPENSBI_CYCLES=0 bash tools/run-linux.sh` for
an unlimited run. Linux build dependencies and separate stages are described
in [Rebuild from clean](REBUILD_FROM_CLEAN.md).

## Build for DE0-CV

```sh
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh all
```

This produces the interactive board RAM image, including the static
[MiNTs Life C application](../examples/life/README.md) as `/bin/life`. It does not build Quartus
hardware or program the FPGA. Follow the [board guide](../fpga/de0-cv/soc/README.md)
for prerequisites, wiring, synthesis, timing signoff, SRAM programming and UART.

With existing dependencies, rebuild only the kernel and RAM image:

```sh
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh kernel
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh image
```

`KERNEL_INIT_MODE` can explicitly select an initramfs mode supported by
`tools/build-busybox-initramfs.sh`. Defaults are `autotest` for `legacy` and
`default` for `de0cv64`. Changing this variable requires rebuilding the kernel
before generating the RAM image.

## Generated artifacts

| Artifact | Path |
|---|---|
| OpenSBI firmware | `build/external/opensbi/build/platform/generic/firmware/fw_jump.bin` |
| OpenSBI symbols for lockstep | Same directory, `fw_jump.elf` |
| Legacy DTB / RAM image | `build/platform/riscv_cpu.dtb`, `opensbi_ram.hex` |
| Board DTB / RAM image | `build/platform/de0cv64/riscv_cpu.dtb`, `opensbi_ram.hex` |
| Legacy autotest kernel | `build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs` |
| Board interactive kernel | `build/external/linux-out/Image-linux-6.12-riscv64-busybox-default-initramfs-de0cv64` |
| Board kernel config / symbols | `build/linux-build-busybox-default-de0cv64/` |

Linux sources reside in Docker volume `mints-linux-sources`, avoiding macOS
case-insensitive filename collisions. Generated artifacts and Linux compiler
executables reside in `build/`; those executables run inside the container.
The board kernel's `-de0cv64` suffix keeps it separate from legacy output.

Whisper lockstep is a separate workflow with additional prerequisites; the
normal Linux rebuild does not install the reference model. See
[the reference integration guide](../tools/whisper_lockstep/README.md) and
[test status](TEST_STATUS.md).
