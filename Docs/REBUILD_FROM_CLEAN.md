# Rebuild from Clean

This guide covers recovery after cloning the repository or deleting `build/`.
The workflows were exercised on an Apple M1 Mac with Docker Desktop. There
are separate simulator and physical-board targets.

## Prerequisites

- Docker Desktop running, with network access for source and package downloads.
- For physical DE0-CV programming: Xcode Command Line Tools and native macOS
  USB-Blaster tools built by `tools/setup-de0cv-programmer.sh`.
- For FPGA synthesis: official Quartus Prime Lite 20.1 Linux installer and
  Cyclone V device package. See [Quartus setup](../fpga/de0-cv/blink/QUARTUS_M1_SETUP.md).

Run all commands from the repository root. Wrappers locate Docker Desktop's
bundled CLI on macOS when needed.

## Simulator target

```sh
bash tools/rebuild-linux.sh all
bash tools/run-linux.sh
```

The first command builds without booting Linux. The second starts the
Verilator run in Docker. Success requires `BUSYBOX-TEST-PASS` without a failure
marker or kernel panic. RTL simulation may take several minutes or longer;
it is not a native-speed virtual machine.

## Physical DE0-CV target

```sh
bash tools/setup-quartus.sh
bash tools/setup-de0cv-programmer.sh
bash tools/build-de0cv-jtag-load.sh
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh all
STAGE=asm bash tools/build-de0cv-soc.sh
```

Quartus setup requires the downloaded official installers and accepts their
EULA for unattended installation. These commands build tools and artifacts;
use the [board guide](../fpga/de0-cv/soc/README.md) for wiring, UART, programming
and CPU release. The selected board profile is 20 MHz, 64 MiB SDRAM, 1 KiB
I/D caches, two-entry ITLB/DTLB, predictor disabled and 100 Hz periodic Linux.

## Linux dependencies and stages

`Dockerfile.linux` builds `mints-linux-verilator:5.046`. The scripts select:

| Dependency | Version |
|---|---|
| Verilator | 5.046 |
| Linux | 6.12 |
| OpenSBI | v1.3.1 |
| BusyBox | 1.36.1 |
| musl-cross-make | `5e8042e63de29f8473fc3b0b831a587ba284e1a8` |
| musl toolchain | GCC 13.3.0, musl 1.2.5, RV64IMAC / LP64 |

Individual stages allow recovery without rebuilding everything:

```sh
bash tools/rebuild-linux.sh sources
bash tools/rebuild-linux.sh toolchain
bash tools/rebuild-linux.sh firmware
bash tools/rebuild-linux.sh busybox
bash tools/rebuild-linux.sh kernel
bash tools/rebuild-linux.sh simulator
bash tools/rebuild-linux.sh image
```

For board firmware, kernel and image stages, prepend `PLATFORM_PROFILE=de0cv64`.
The board `all` workflow omits the Verilator simulator build. A stage assumes
its dependencies already exist. `JOBS=4` is the default; lower it on a
memory-constrained host. Stage logs are written to `build/logs/`.

## Where state is stored

| Location | Contents | Included in Git? |
|---|---|---|
| `build/` | Toolchain, firmware, kernels, DTBs, simulator, Quartus output and logs | No |
| `local/` | Native FPGA tools, external checkouts, installers and local notes | No |
| Docker volume `mints-linux-sources` | Linux source and musl compiler build intermediates | No |
| Docker volume `mints-quartus-20.1` | Installed Quartus and device support | No |
| Tracked scripts / fragments / RTL | Inputs and selected build configuration | Yes |

`make clean` removes the full `build/` directory, including compiler and boot
artifacts. It leaves `local/`, Docker images and volumes. A fresh Mac needs
the installers and dependencies again; Git is not a backup of those outputs.

The Linux build installs full Linux UAPI headers into the musl sysroot using
`build/linux-headers-out`, separate from the kernel source/output trees.

## Reproducibility boundaries

The M1 simulator workflow reached Linux `BUSYBOX-TEST-PASS`. The physical-board
workflow subsequently passed Quartus signoff and interactive Linux operation;
see [test status](TEST_STATUS.md) for the distinct scopes.

This is a reproducible procedure, not a bit-for-bit artifact guarantee.
Ubuntu base tags/package repositories, Docker versions, dependency services,
build timestamps and retained intermediate files can change results. For an
independent source rebuild, use a fresh checkout and a new `SOURCES_VOLUME`
name. Do not point experimental rebuilds at a source volume you need to retain.
Quartus and native-tool dependencies have their own setup scripts and state.

Always sign off rebuilt FPGA outputs and verify the corresponding board RAM
image. Timing and functional results from an earlier artifact do not certify
a newly generated artifact. Whisper and external ISA tests are separate from
the Linux rebuild workflow.
