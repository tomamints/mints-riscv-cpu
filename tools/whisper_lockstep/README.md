# Whisper Lockstep

Scope: optional simulator architectural reference. The results below are
historical checkpoints, not a fresh run for the final DE0-CV profile.

This directory contains the Whisper reference wrapper used by the Verilator
lockstep build.

One recorded checkpoint (the exact instruction count is workload-dependent):

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

## Prerequisites

Use a Linux build environment so Verilator, the reference library and generated
objects share an executable/object format. Do not mix macOS Mach-O and Linux ELF
objects. The ordinary `tools/rebuild-linux.sh` workflow does not install Whisper.

The Makefile expects an external `whisper/` checkout and
`whisper/build-Linux/librvcore.a` by default (`WHISPER_DIR`, `WHISPER_BUILD_DIR`
and `WHISPER_LIB` are configurable). The source revision and local compatibility
patch are documented in [third-party patches](../../third_party/patches/README.md).
Apply that patch and build the reference library using the external project's
build instructions and dependencies. `Dockerfile.lockstep` supplies a compiler
and Verilator; it does not install the reference source/library or all Linux
boot dependencies automatically. There is no single clean rebuild command here
that certifies a new lockstep installation.

## Build and run with prepared dependencies

From the repository root **inside the prepared Linux environment**, with the
legacy firmware, DTB and autotest image already built:

```sh
make build-lockstep DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=0
make run-opensbi-lockstep \
  DCACHE_LINE_COUNT=512 DCACHE_STORE_BUFFER_DEPTH=8 DCACHE_WRITE_BACK=0 \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

Require a `LOCKSTEP` pass through `BUSYBOX-TEST-PASS`, without a mismatch.
A previous pass count is not a required invariant. These checks do not establish
board-level timing, physical UART behavior or untested interrupt schedules.
See [test status](../../Docs/TEST_STATUS.md).

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

## Reference synchronization

The integration handles these synchronization and comparison cases:

```text
non-retiring exception synchronization
MTIMER/SEIP one-shot interrupt injection
WFI interrupt EPC compensation
instruction page fault STVAL PC selection
UART TX stream pass-token detection
```
