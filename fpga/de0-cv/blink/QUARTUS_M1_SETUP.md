# Quartus 20.1 on M1: environment checkpoint

2026-11-09, Apple M1 / macOS 15.7.5 / Docker Desktop.
Quartus runs in an amd64 Ubuntu 20.04 container; USB-Blaster programming uses
native macOS openFPGALoader. This is a tested setup in progress, not an official
macOS Quartus port.

Download these two files from the authenticated
[official distribution page](https://www.altera.com/downloads/fpga-development-tools/quartus-prime-lite-edition-design-software-version-20-1-linux)
into `~/Downloads` (or set `QUARTUS_DOWNLOAD_DIR`):

| File | Bytes | Official SHA1 |
|---|---:|---|
| QuartusLiteSetup-20.1.0.711-linux.run | 2114215146 | 00a2909e7cf0e174a5528d110608348174aac9b3 |
| cyclonev-20.1.0.711.qdz | 1446097745 | c4ee3fa13f1dfbd3d95c8baa9fece7b864ef5d2c |

Both downloaded files matched these checksums on this M1.

```bash
bash tools/setup-quartus.sh
bash tools/build-de0cv-blink-docker.sh
bash tools/program-de0cv-blink.sh
```

Setup verifies the downloads, builds `Dockerfile.quartus`, and installs into the
Docker volume `mints-quartus-20.1` at `/opt/intelFPGA_lite/20.1`.
It accepts the installer EULA for unattended installation. Installers stay in
ignored `local/quartus-installers/`; generated files and logs stay in `build/`.
The Docker base image digest and Quartus release/checksums are fixed; Ubuntu
package repositories and Docker Desktop remain external version dependencies.
The proprietary installers and installed volume are not backed up by Git.

Confirmed: unattended installation completed and `quartus_sh --version` returned
`Version 20.1.0 Build 711 06/05/2020 SJ Lite Edition`.

Initial compile failed at `quartus_map`; direct execution reported
`realloc(): invalid pointer`, exit 134, with approximately 7 GiB available RAM.
The generic flow message suggesting memory shortage does not establish its cause.
Investigating runtime library compatibility. Fit, STA, SOF generation and physical
blink are still unverified at this checkpoint. Do not run the programming step
until a successful build has produced and checked the SOF.
