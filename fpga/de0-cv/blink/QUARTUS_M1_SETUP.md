# Quartus 20.1 on Apple M1

This repository builds Cyclone V designs using Quartus Prime Lite 20.1 in an
x86_64 Linux Docker container on Apple Silicon. USB-Blaster programming uses
native macOS openFPGALoader. Quartus is not a native macOS application in this
workflow. The setup has built the blink design and the integrated
[20 MHz Linux SoC](../soc/README.md).

## Prerequisites and installers

Start Docker Desktop and download these official Linux files into `~/Downloads`
(or set `QUARTUS_DOWNLOAD_DIR`) from the
[Quartus Prime Lite 20.1 distribution page](https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-20-1-linux).
The provider may require account authentication. Redistribution of the
proprietary installers is not part of this repository.

| File | Bytes | SHA1 checked by setup |
|---|---:|---|
| QuartusLiteSetup-20.1.0.711-linux.run | 2114215146 | `00a2909e7cf0e174a5528d110608348174aac9b3` |
| cyclonev-20.1.0.711.qdz | 1446097745 | `c4ee3fa13f1dfbd3d95c8baa9fece7b864ef5d2c` |

## Install and build

From the repository root, after reviewing and accepting the installer EULA:

```sh
bash tools/setup-quartus.sh
bash tools/build-de0cv-blink-docker.sh
```

Setup verifies the installer checksums, builds `Dockerfile.quartus`, and installs
Quartus into Docker volume `mints-quartus-20.1` at `/opt/intelFPGA_lite/20.1`.
It passes `--accept_eula 1` for unattended installation. The selected version is
`20.1.0 Build 711` with Cyclone V support.

Installers are retained in ignored `local/quartus-installers/`; generated designs
and logs are in `build/`. Neither the installed Docker volume nor the installers
are backed up by Git. A new Mac needs those dependencies again.

The build runners preload `/lib/x86_64-linux-gnu/libudev.so.1`, a workaround
for an observed Quartus startup crash in this environment. They also convert
SOF to RBF for the native SRAM programming backend. Use the provided runners
rather than attempting to execute Linux Quartus binaries directly on macOS.

## Native programming

```sh
bash tools/setup-de0cv-programmer.sh
local/fpga-tools/bin/openFPGALoader --detect -c usb-blaster
bash tools/program-de0cv-blink.sh
```

This setup builds pinned openFPGALoader v1.2.0 and its native dependencies under
`local/`. Programming checks the device ID and writes volatile SRAM only.
The integrated SoC uses separate build/program scripts; follow
[the board guide](../soc/README.md) for Linux.

## Validation and reproducibility

The blink build used 19 ALMs and 28 registers and passed all four timing
corners at 50 MHz; physical LED blinking was observed. The integrated Linux
SoC has its own 20 MHz constraints and resource/timing results. Passing the
blink test does not establish timing or functionality for another design.

The Quartus release/installers and Docker base digest are selected by the
scripts, while package repositories, Docker versions, retained state and build
metadata can still vary. Rebuilt FPGA artifacts require their own signoff and
physical validation. See [rebuild boundaries](../../../Docs/REBUILD_FROM_CLEAN.md).
