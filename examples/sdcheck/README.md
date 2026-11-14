# Read-only microSD check

`sdcheck /dev/mmcblk0` sets the card read-only and verifies a 512-byte read.
For a partition, use `sdcheck /dev/mmcblk0p1`; the whole card and partition are
both protected. It prints capacity and a SHA256 of the first sector, with
`SD-READ-PASS` only after a complete read. It never formats, repairs or mounts
the card. The helper is installed in the standard BusyBox initramfs.

See [SD hardware, kernel configuration and read-only mount commands](../../fpga/de0-cv/sd/README.md).
