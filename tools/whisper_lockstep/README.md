# Whisper lockstep phase 1

Copy this directory to:

```text
$HOME/risc-v-cpu/tools/whisper_lockstep
```

Build from the repository root:

```bash
make -f tools/whisper_lockstep/Makefile whisper-api-smoke
```

Run 100 OpenSBI instructions:

```bash
build/whisper-lockstep/whisper_api_smoke \
  build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
  build/platform/riscv_cpu.dtb \
  100
```

Expected initial PC sequence:

```text
80000000
80000004
80000008
8000000c
80000658
8000065a
```

The next phase is to add `WhisperRef.cpp` to the Verilator executable and call
`step()` whenever RTL asserts `retire_valid`.
