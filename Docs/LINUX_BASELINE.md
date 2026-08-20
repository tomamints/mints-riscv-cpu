# Linux Baseline

Last updated: 2026-08-20

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
[PERF] cycles=100000000 retired=41780831 cpi_x1000=2393 ipc_x1000=417
```

Key frontend counters for this checkpoint:

```text
[PERF-FETCH-STALL] fifo_full=7320628 control_recovery=14156540 translation_issue=19680007 translation_req_wait=0 translation_rsp=22023 icache_req=2586028 icache_rsp=5765099 fault=0 no_request=0
[PERF-CONTROL] branch=1246862 jal=726042 jalr=127390 trap=1611 return=1679 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=5561110 hit=4314232 miss=1246878 hit_rate_x1000=775
[PERF-BTB] jalr=421644 hit=294253 miss=127391 hit_rate_x1000=697 entries=32
[PERF-RAS] return=352959 hit=275654 miss=77305 fallback_btb=131 hit_rate_x1000=780 depth=8
```

Previous stable checkpoint before the latest frontend fetch handoff work:

```text
[PERF] cycles=100000000 retired=39534138 cpi_x1000=2529 ipc_x1000=395
```

The current frontend work increases the fixed-window retired instruction count
by about 2.25M instructions and moves CPI from about 2.529 to 2.393 on the same
100M-cycle Linux boot workload.

## Stable Configuration

```text
DCACHE_LINE_COUNT=512
DCACHE_STORE_BUFFER_DEPTH=8
DCACHE_WRITE_BACK=0
```

The write-back D-cache mode exists as an experiment, but the stable public
baseline remains write-through.
