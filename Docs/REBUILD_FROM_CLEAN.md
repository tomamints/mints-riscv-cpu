# Rebuild From Clean

Last updated: 2026-11-09

This document lists the artifacts needed after deleting `build/`.

## Docker rebuild on Apple Silicon (2026-11-09)

With Docker Desktop running, build the Linux simulator and all boot artifacts:

```bash
bash tools/rebuild-linux.sh
```

This command only builds. Start the Linux BusyBox autotest separately:

```bash
bash tools/run-linux.sh
```

The run uses a 300M-cycle limit and saves output to
`build/logs/linux-boot.log`. Success requires `BUSYBOX-TEST-PASS` with no
`BUSYBOX-TEST-FAIL` or kernel panic. Expect simulation to take several minutes;
this is RTL simulation, not a virtual machine running at native speed.
Use `OPENSBI_CYCLES=0 bash tools/run-linux.sh` for an unlimited run and Ctrl-C
to stop it. The autotest finishes in a sleep loop, rather than a shell prompt.

The build uses `Dockerfile.linux` / `mints-linux-verilator:5.046` and downloads:

- Verilator 5.046
- OpenSBI v1.3.1
- Linux 6.12
- BusyBox 1.36.1, statically linked for RV64IMAC / LP64
- musl-cross-make commit `5e8042e63de29f8473fc3b0b831a587ba284e1a8`,
  GCC 13.3.0 and musl 1.2.5 (with that checkout's patches)

Linux sources and compiler build intermediates live in the Docker volume
`mints-linux-sources`, avoiding macOS filename case collisions. The compiler,
firmware, kernel, and simulator outputs live in this checkout. The compiler
and simulator are Linux executables; run them in the container.
`make clean` deletes the checkout's build artifacts, including the installed
compiler, but keeps the Docker volume and image.

For recovery or incremental work, individual stages are available:

```bash
bash tools/rebuild-linux.sh sources
bash tools/rebuild-linux.sh toolchain
bash tools/rebuild-linux.sh firmware
bash tools/rebuild-linux.sh busybox
bash tools/rebuild-linux.sh kernel
bash tools/rebuild-linux.sh simulator
```

Each stage saves a log under `build/logs/`. `JOBS=4` is the default;
lower it for memory-constrained machines. Whisper lockstep and the external
`riscv-tests` suite are separate from this Linux boot build.

### M1 rebuild checkpoint and remaining variability

On 2026-11-09, the boot artifacts and Verilator simulator were built from
external sources on an **Apple M1 MacBook Air, 16GiB RAM, macOS 15.7.5
(24G624)**. Docker Desktop 4.98.0 / Docker Engine 29.9.2 ran native ARM64
Ubuntu 24.04 containers with 8 CPUs and about 7.75GiB RAM available.
The stable cache parameters were 512 lines, 8 store-buffer entries, and
write-through mode. **The user then ran `bash tools/run-linux.sh` and
confirmed Linux 6.12.0 boot and `BUSYBOX-TEST-PASS` on this M1 environment.**
The local `build/logs/linux-boot.log` also contains the pass marker, after
the uname, root listing, working-directory, mkdir, file write/read, and
cleanup checks. The running kernel identified itself as:

```text
Linux (none) 6.12.0 #3 Mon Nov  9 08:49:42 UTC 2026 riscv64 GNU/Linux
BUSYBOX-TEST-PASS
```

After building the individual stages, `bash tools/rebuild-linux.sh` also
completed successfully with the existing sources/build intermediates. The
run command was first checked with `make -n`; the user performed the actual
Linux boot afterward.
The local checkpoint includes `build/logs/rebuild-all.log`,
`environment.log`, `ubuntu-packages.tsv`, `artifacts.sha256`,
`linux-run-dryrun.log`, and `linux-boot.log`. These generated files are
intentionally outside Git; the recorded environment and repair steps in this
document are tracked.

The clean checkout exposed these missing prerequisites, now handled by the
Docker rebuild path:

- `core/test/bin2hex.py` was referenced but absent. The tracked replacement
  is `tools/bin2hex.py`, and the Makefile now uses it.
- External source retrieval was not fully scripted. The new wrapper fetches
  the specified OpenSBI, Linux, BusyBox, and musl-cross-make versions.
- The toolchain's minimal Linux headers omit `linux/kd.h`, needed by BusyBox.
  The build now installs full Linux 6.12 UAPI headers into its sysroot.
- Installing those headers in the Linux source tree interferes with the
  separate kernel build. Header generation now uses `build/linux-headers-out`.
- Docker's CLI and credential helper may not be on a new Mac's `PATH`.
  The wrappers add Docker Desktop's bundled binary directory when present.

This is a recorded build and Linux boot checkpoint, not a claim of bit-for-bit
reproducibility.
`ubuntu:24.04` and Ubuntu package repositories can change; network services
must remain accessible. Kernel timestamps and build metadata can also change
artifact hashes. Linux, BusyBox, and compiler build intermediates persist in
the source volume and can affect incremental rebuilds. For an independent
fresh build, use a separate fresh checkout and a new `SOURCES_VOLUME` name.
The source volume can be retained for subsequent incremental builds.

Whisper architectural lockstep validation and FPGA operation were not tested
in this M1 rebuild session.

`make clean` removes Verilator outputs and the full `build/` directory. That
also removes OpenSBI, Linux, BusyBox, generated DTBs, and test artifacts.

## Minimal Rebuild Order

1. Build or install the RISC-V bare-metal toolchain.
2. Build OpenSBI `fw_jump.bin` and `fw_jump.elf`.
3. Build the Linux DTB from `platform/riscv_cpu.dts`.
4. Build the BusyBox initramfs image.
5. Build the Linux `Image` with the initramfs.
6. Build the Verilator simulator.
7. Run the Linux or lockstep baseline.

## Expected Artifact Paths

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
build/external/opensbi/build/platform/generic/firmware/fw_jump.elf
build/platform/riscv_cpu.dtb
build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs
```

## OpenSBI

OpenSBI is expected under:

```text
build/external/opensbi
```

The known-good firmware is OpenSBI v1.3.1 `fw_jump`.

## Linux Images

The two commonly used Linux images are:

| Image | Use |
|---|---|
| `Image-linux-6.12-riscv64-busybox-autotest-initramfs` | correctness and Whisper lockstep |
| `Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs` | bounded performance runs |

## Verify

Run the stable performance checkpoint:

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

Run the correctness checkpoint:

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```
