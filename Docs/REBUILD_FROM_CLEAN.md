# Rebuild From Clean

Last updated: 2026-08-14

This document lists the artifacts needed after deleting `build/`.

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
