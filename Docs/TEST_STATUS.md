# Test Status

Last updated: 2026-08-14

This document summarizes the current public test status of MiNTs-CPU.

## Main Regression Gates

| Test | Status | Notes |
|---|---|---|
| riscv-tests | Pass in current maintained scope | RV64IMAC-oriented tests and selected supervisor/custom tests |
| custom C tests | Pass in current maintained scope | UART, ACLINT, PLIC, trap, and MMU-focused tests |
| Linux BusyBox autotest | Pass | OpenSBI -> Linux 6.12 -> BusyBox `/init` autotest |
| Whisper lockstep | Pass | BusyBox autotest pass marker after 61,610,275 compared instructions |

## Strongest Correctness Checkpoint

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## Useful Commands

Run the current riscv-tests set:

```bash
make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full
```

Run Linux BusyBox autotest:

```bash
make run-opensbi-input \
  DCACHE_LINE_COUNT=512 \
  DCACHE_STORE_BUFFER_DEPTH=8 \
  DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

Run Whisper lockstep:

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

## Notes

Passing the current tests does not imply full RVA23 compliance. The current
claim is narrower: MiNTs-CPU is a Linux-capable RV64IMAC CPU/SoC prototype with
Whisper lockstep validation through the BusyBox autotest path.
