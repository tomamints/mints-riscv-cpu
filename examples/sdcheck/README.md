# Read-only microSD check

`sdcheck /dev/mmcblk0` sets the card read-only and verifies a 512-byte read.
For a partition, use `sdcheck /dev/mmcblk0p1`; the whole card and partition are
both protected. It prints capacity and a SHA256 of the first sector, with
`SD-READ-PASS` only after a complete read. It never formats, repairs or mounts
the card. The helper is installed in the standard BusyBox initramfs.

See [SD hardware, kernel configuration and read-only mount commands](../../fpga/de0-cv/sd/README.md).

## Optional persistence test on a test card

`sdverify create <file>` creates a new 64 KiB deterministic-pattern file and
fsyncs both file and parent directory. It refuses an existing path or symlink.
`sdverify verify <file>` reads only and checks every byte and the exact length.
A failed create can leave its new file for inspection; it does not remove or
replace anything automatically.

Only use create on a card approved for writes. First complete the read-only
check. Then enable writes on the card/partition and mount it read-write,
create `/mnt/sd/mints-verify.bin`, unmount, remount read-only and run verify.
The remount avoids treating an immediate read from the writer's file cache
as storage evidence. Remove only that newly created test file if cleanup is
wanted. No formatting or filesystem repair is part of this procedure.
A successful remount test is not a power-loss durability test.

```sh
sdverify create /mnt/sd/mints-verify.bin
# Unmount and remount the card read-only before this step:
sdverify verify /mnt/sd/mints-verify.bin
```

Host-side failure tests (no card access): `python3 tools/test-sdverify.py`.
