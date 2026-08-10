# Linux Setup

This document describes the current Linux/OpenSBI/BusyBox setup for
**MiNTs-CPU**.

## Required Artifacts

The normal Linux run needs:

```text
OpenSBI fw_jump.bin
OpenSBI fw_jump.elf        # only needed for Whisper lockstep
Linux Image with built-in initramfs
DTB generated from platform/riscv_cpu.dts
Verilator simulator
```

Current known-good paths:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
build/external/opensbi/build/platform/generic/firmware/fw_jump.elf
build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs
build/platform/riscv_cpu.dtb
```

## OpenSBI

OpenSBI is built externally under `build/external/opensbi`.

Helper script:

```bash
tools/build-opensbi.sh
```

Expected output:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
build/external/opensbi/build/platform/generic/firmware/fw_jump.elf
```

OpenSBI should report:

```text
Platform Name             : MiNTs-CPU
Platform Console Device   : uart8250
Platform IPI Device       : aclint-mswi
Platform Timer Device     : aclint-mtimer @ 50000000Hz
Boot HART Base ISA        : rv64imac
Boot HART ISA Extensions  : time
Boot HART PMP Count       : 8
Domain0 Next Address      : 0x0000000080200000
Domain0 Next Arg1         : 0x0000000087f00000
Domain0 Next Mode         : S-mode
```

## DTB

Generate the device tree blob after changing `platform/riscv_cpu.dts`:

```bash
make dtb
```

Current platform assumptions:

```text
RAM        0x80000000, 128MiB
Linux      0x80200000
DTB        0x87f00000
UART       0x10000000
PLIC       0x0c000000
timebase   50000000
```

## BusyBox Userland

BusyBox must be built for `rv64imac/lp64` soft-float. Do not use a prebuilt
double-float riscv64 userland image.

Build the musl toolchain:

```bash
tools/build-rv64imac-musl-toolchain.sh
```

Build static BusyBox:

```bash
tools/build-rv64imac-busybox.sh
```

Build a Linux image with BusyBox initramfs:

```bash
INIT_SCRIPT_MODE=autotest \
LINUX_SRC_VOLUME=linux-6.12-src \
LINUX_OUT=build/external/linux-out \
JOBS=4 \
tools/build-linux-busybox-initramfs-image.sh
```

The default output name is:

```text
build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
```

For manual command-loop testing:

```bash
INIT_SCRIPT_MODE=cmdloop-ttyS0 \
IMAGE_NAME=Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
LINUX_SRC_VOLUME=linux-6.12-src \
LINUX_OUT=build/external/linux-out \
JOBS=4 \
tools/build-linux-busybox-initramfs-image.sh
```

The Linux source is usually kept in the Docker volume `linux-6.12-src` because
macOS case-insensitive filesystems can collide on Linux documentation paths.

## Run Linux

Interactive simulator:

```bash
make build-input
```

Run the BusyBox autotest image:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

Expected end marker:

```text
BUSYBOX-TEST-PASS
```

Run the command-loop image:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=0
```

Expected wait point:

```text
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

`MARK-B` means `/dev/ttyS0` is waiting for input. For example:

```text
echo OK
```

should produce:

```text
MARK-C: read returned
status=0
line=[echo OK]
OK
MARK-B: before read
```

## Lockstep Run

Use Docker for lockstep builds so the Whisper library and generated Verilator
objects are all Linux ELF objects.

```bash
cd "$HOME/risc-v-cpu"

DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    rm -rf obj_dir_lockstep &&
    make build-lockstep &&
    make run-opensbi-lockstep \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES=0
  ' 2>&1 | tee /tmp/lockstep-autotest.log
```

Expected pass:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=...
[LOCKSTEP] PASS: ... instructions compared (BusyBox autotest passed)
```

Useful grep:

```bash
grep -E 'BUSYBOX-TEST|BusyBox autotest|LOCKSTEP.*PASS|LOCKSTEP-MISMATCH' /tmp/lockstep-autotest.log
```

## Performance Run

Use bounded cycle counts so Verilator final blocks print the summary.
For iteration, 100M cycles is usually enough.

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY
```

Do not use broad trace plusargs during performance runs.

