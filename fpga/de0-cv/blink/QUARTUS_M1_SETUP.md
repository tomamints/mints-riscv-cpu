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
Preloading `/lib/x86_64-linux-gnu/libudev.so.1` allowed `quartus_map` to start
and report HDL errors instead. The Docker build runner includes this setting.
This workaround is also described by the original reporter in the
[Altera community](https://community.altera.com/discussions/quartus-prime/running-quartus-prime-standard-on-wsl-crashes-in-libudev-so/260408/replies/260415).
The blink module's derived `localparam` was moved from the parameter port list
into the module body for Quartus 20.1 parser compatibility.
Final result: full compilation, Fit and STA passed; 19 ALMs, 28 registers.
All four timing corners passed at 50 MHz. Minimum setup slack 15.813 ns,
hold 0.191 ns, recovery 18.169 ns, removal 0.499 ns; all TNS zero.
Setup and hold were reported fully constrained. See README for four warnings.
The Verilator regression passed again after the parser compatibility change.

openFPGALoader rejects SOF for this SRAM backend. `quartus_cpf -c` converted SOF
to RBF successfully; the build script now includes that conversion.
Native USB-Blaster SRAM programming reached 100%, reported Done and exited 0.
The user confirmed the physical LED blink. No flash programming was performed.

Recorded artifact SHA256 (a rebuilt SOF can include changing metadata):

- SOF: `78bce740a0810573a2dd43f12a3d033d2483cb13787fabca43633430aa82edeb`
- RBF: `b426226caa9d7f63c70364cb2eafa170c7e845fdcb9e602b33020b62b828fa36`

The container also generates en_US.UTF-8 to satisfy Quartus qenv.sh.
The final locale-equipped image built successfully; compilation and programming
above used the preceding image with a harmless missing-locale warning.
Logs are local under `build/logs/`: quartus-install, quartus-version,
de0cv-blink-quartus, de0cv-blink-convert, de0cv-blink-program.
