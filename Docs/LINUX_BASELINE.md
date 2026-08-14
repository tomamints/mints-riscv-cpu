# Linux Baseline

Last updated: 2026-08-14

This document defines the Linux regression baseline used before and after
microarchitectural changes.

## Primary Correctness Baseline

The primary correctness gate is the BusyBox autotest initramfs:

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

Expected pass marker:

```text
BUSYBOX-TEST-PASS
```

## Lockstep Baseline

Whisper lockstep is the strongest architectural check:

```bash
make run-opensbi-lockstep \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

Expected pass marker:

```text
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## Performance Baseline

The stable performance checkpoint uses the command-loop initramfs and a bounded
100M-cycle run:

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=100000000 \
  SIM_EXTRA_ARGS=+PERF_SUMMARY \
  2>&1 | tee /tmp/perf-100m.log
```

Representative stable result:

```text
[PERF] cycles=100000000 retired=39534138 cpi_x1000=2529 ipc_x1000=395
```

## Stable Configuration

```text
DCACHE_LINE_COUNT=512
DCACHE_STORE_BUFFER_DEPTH=8
DCACHE_WRITE_BACK=0
```

The write-back D-cache mode exists as an experiment, but the stable public
baseline remains write-through.
