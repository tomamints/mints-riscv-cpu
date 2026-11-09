# Test Status

Last updated: 2026-11-09

This document summarizes the current public test status of MiNTs-CPU.

## Main Regression Gates

On 2026-11-09, a fresh Apple M1 environment was rebuilt using the Docker
workflow, and the user confirmed Linux 6.12.0 boot through
`BUSYBOX-TEST-PASS`. The local boot log corroborates the pass marker. See
[the M1 checkpoint](REBUILD_FROM_CLEAN.md#m1-rebuild-checkpoint-and-remaining-variability)
for the environment and repaired prerequisites. Whisper lockstep was not
rerun in this session.

The separate DE0-CV UART PHY also passed its bit-level unit tests at 50MHz
and 20MHz on 2026-11-09 (`bash tools/test-de0cv-uart.sh`), with clean RTL
`-Wall` lint. This does not cover 16550/FIFO/IRQ integration or physical UART
operation. The DE0-CV blink simulation passed its real 25M-cycle divider,
reset and small-divider checks (`bash tools/test-de0cv-blink.sh`); FPGA
configuration and timing closure are still pending.

| Test | Status | Notes |
|---|---|---|
| riscv-tests | Pass in current maintained scope | RV64IMAC-oriented tests and selected supervisor/custom tests |
| custom C tests | Pass in current maintained scope | UART, ACLINT, PLIC, trap, and MMU-focused tests |
| Linux BusyBox autotest | Pass | OpenSBI -> Linux 6.12 -> BusyBox `/init` autotest |
| Whisper lockstep | Pass | BusyBox autotest pass marker after 61,610,275 compared instructions |
| `rv64ui-p-fence_i` | Pass | Fast regression for `fence.i` and frontend predictor invalidation |

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

Run the frontend-sensitive `fence.i` regression:

```bash
python3 tools/run_riscv_tests.py obj_dir/sim core/test/share rv64ui-p-fence_i \
  --rom build/test/bootrom.hex \
  --ram_base 0x80000000 \
  -o results/rv64ui-fence-i \
  -t 10
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
