# Linux Milestones

Last updated: 2026-08-14

This document defines what "Linux works" means for MiNTs-CPU.

## Current Passed Milestone

The current end-to-end target is:

```text
MiNTs-CPU
  -> OpenSBI v1.3.1 fw_jump
  -> Linux 6.12.x
  -> built-in initramfs
  -> rv64imac/lp64 static BusyBox
  -> /init autotest
  -> BUSYBOX-TEST-PASS
```

This path is also validated by Whisper lockstep:

```text
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## What Is Covered

The BusyBox autotest path exercises:

- OpenSBI handoff to S-mode Linux
- Sv39 virtual memory
- U-mode `/init`
- basic syscalls
- procfs/sysfs/devtmpfs/tmpfs mounts
- BusyBox command execution
- file create/read/remove on tmpfs
- timer and external interrupt paths used during boot
- UART console output

## Baselines

Primary regression baseline:

```text
Linux BusyBox autotest + Whisper lockstep PASS
```

Manual debug baseline:

```text
cmdloop-ttyS0 initramfs
```

The command-loop image is useful for UART and manual Linux checks, but the
autotest image is the main correctness gate.

## Remaining Linux Work

- improve the fully interactive TTY shell path
- add more userspace stress tests
- add a persistent root filesystem or block device path
- make the lockstep Docker image fully reproducible from public scripts
