# Third-party Patches

Last updated: 2026-08-14

This directory contains small local patches needed to reproduce MiNTs-CPU
verification flows with third-party tools that are not vendored in this
repository.

## Tenstorrent Whisper

`whisper-mints-lockstep.patch` is applied to a local Tenstorrent Whisper
checkout used by the lockstep harness.

Reference revision used when the patch was captured:

```text
cc36ae56b31897d20ba115ba7c086ae35664d8b4
```

Apply from the MiNTs-CPU repository root:

```bash
git clone https://github.com/tenstorrent/whisper.git whisper
git -C whisper checkout cc36ae56b31897d20ba115ba7c086ae35664d8b4
git -C whisper apply ../third_party/patches/whisper-mints-lockstep.patch
```

The patch keeps Whisper aligned with the RTL lockstep model by:

- limiting supported virtual memory modes to Bare and Sv39
- treating translated cross-page misaligned load/store accesses as address
  misalignment traps, matching the RTL `memunit`
