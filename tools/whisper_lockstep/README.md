# Whisper Lockstep

This directory contains the Whisper reference wrapper used by the Verilator
lockstep build.

Current validated checkpoint:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## What Is Compared

The lockstep harness compares committed architectural effects after RTL reaches
the OpenSBI entry point at `0x80000000`.

Compared fields include:

```text
PC
privilege mode
integer register writeback
memory access metadata
memory write data
trap / interrupt synchronization points
```

The harness also synchronizes asynchronous RTL events that Whisper would not
take at exactly the same instruction boundary by itself:

```text
MTIMER interrupt
SEIP interrupt
non-retiring synchronous exceptions
WFI interrupt EPC behavior
```

For Linux autotest runs, the UART TX stream is watched for:

```text
BUSYBOX-TEST-PASS
```

When that token is seen, the simulator exits normally.

## Build And Run

Use the Docker image used for lockstep development. This avoids mixing macOS
Mach-O objects with Linux ELF objects.

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

Check result:

```bash
grep -E 'BUSYBOX-TEST|BusyBox autotest|LOCKSTEP.*PASS|LOCKSTEP-MISMATCH' /tmp/lockstep-autotest.log
```

## Useful Plusargs

Trace only a small instruction-order window:

```text
+LOCKSTEP_TRACE_START=<order>
+LOCKSTEP_TRACE_END=<order>
```

Stop at a compared instruction order:

```text
+LOCKSTEP_STOP_ORDER=<order>
```

Example:

```bash
SIM_EXTRA_ARGS="+LOCKSTEP_TRACE_START=55059000 +LOCKSTEP_TRACE_END=55059400 +LOCKSTEP_STOP_ORDER=55059450"
```

Use broad traces sparingly. They produce huge logs and can obscure the actual
mismatch or pass marker.

## Known Important Fixes

Recent lockstep-related fixes:

```text
non-retiring exception synchronization
MTIMER/SEIP one-shot interrupt injection
WFI interrupt EPC compensation
instruction page fault STVAL PC selection
UART TX stream pass-token detection
```
