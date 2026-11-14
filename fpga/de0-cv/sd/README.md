# microSD over SPI

This board build adds a small, full-duplex SPI host for the DE0-CV microSD
socket. CPU, SDRAM and timer stay at 20 MHz; VGA and UART are retained.
It is an SD memory-card path, not an SDIO or four-bit SD controller.

## Hardware interface

| Signal | Socket signal | FPGA pin | Direction |
|---|---|---|---|
| SD_CLK | SD_CLK | H11 | Output |
| SD_MOSI | SD_CMD | B11 | Output |
| SD_MISO | SD_DATA0 | K9 | Input, weak pull-up |
| SD_CS_N | SD_DATA3 | C11 | Output, active low |

Pins follow table 3-12 of the
[Terasic DE0-CV manual](https://www.engr.newpaltz.edu/~bai/EGC221/DE0_CV_User_Manual_112.pdf).
SD_DATA1/2 are unused in SPI mode. The board provides 3.3 V card power;
there is no software power switch or separate card-detect/write-protect pin.

The host transfers eight-bit words, MSB first, SPI mode 0. One byte takes 16
half-periods of 25 CPU cycles: **400 kHz fixed**. There is one active-low chip
select, no FIFO, DMA or interrupt. SCLK idles low, MOSI idles high and CS is
high after reset. Clocks can be emitted while CS is high, as SD initialization
requires. MISO uses two CPU-clock synchronizers and is sampled on rising SCLK;
the preceding falling edge is 1.25 microseconds earlier.

The fixed rate is within SD's initialization limit and matches Linux 6.12
`mmc_spi`'s 400 kHz minimum. It does not increase for data transfers. Throughput
is limited by per-byte CPU polling as well as the SPI clock; no benchmark rate
is claimed.

The SDC checks a conservative 20 MHz source-clock output budget of max 5 ns,
min 0 ns and an assumed 6 pF output load. Only MISO-to-first-synchronizer is
cut as an asynchronous input; internal paths remain timed. These budgets are
not a measured card/cable timing model. Slow SCLK spacing and the MISO pipeline
are separately checked by simulation.

## Registers and Linux binding

Base address: `0x40000040`, separate from GPIO/video at `0x40000000`.
Use aligned 32-bit accesses; data is in the corresponding lane of the 64-bit
Membus. Partial stores are ignored. One request is accepted until valid drops.

| Offset | Read | Write |
|---|---|---|
| 0x00 | Last RX byte; clears RRDY | Ignored |
| 0x04 | Zero | TX byte; starts eight clocks, or sets TOE if busy |
| 0x08 | ROE bit 3, TOE bit 4, TMT bit 5, TRDY bit 6, RRDY bit 7, E bit 8 | Clears ROE/TOE |
| 0x0c | SSO bit 10 | SSO bit 10 |
| 0x10 | Zero | Ignored |
| 0x14 | Select bit 0 | Select bit 0 |

CS is low while both SSO and select bit 0 are set. RX overrun is flagged if
an unread byte is replaced. Interrupt mask bits and other chip selects are
not implemented. This is the register subset used by the unmodified Linux
[`spi_altera` polling driver](https://github.com/torvalds/linux/blob/v6.12/drivers/spi/spi-altera-core.c)
and [`mmc_spi`](https://github.com/torvalds/linux/blob/v6.12/drivers/mmc/host/mmc_spi.c),
not a general replacement for every configuration of the Altera SPI IP.
The platform device uses `altr,spi-1.0`, with an `mmc-spi-slot` child at CS 0.
Only the eight-bit/mode-0 path used by that child is supported.

The board kernel builds SPI, MMC block, VFAT/exFAT/ext4, MBR/GPT partition
support and 437/ISO-8859-1/UTF-8 character sets in. No external module installation is needed.
The GPIO UIO resource and SPI register resource are disjoint; applications
must not access SPI through the page-aligned GPIO UIO mapping.

## First card check: read only

Use a matching SD-enabled FPGA image and Linux image; an older FPGA image
has no SPI register window and cannot run this device tree safely. Rebuild
and program using the [SoC procedure](../soc/README.md). Use an SD memory card
with an existing filesystem for the first mount. SDIO is not supported. No automatic mount or format is performed.

From the Linux UART shell:

```sh
dmesg | busybox tail -30
cat /proc/partitions
sdcheck /dev/mmcblk0
# If the card has a first partition:
sdcheck /dev/mmcblk0p1
mkdir -p /mnt/sd
mount -t vfat -o ro /dev/mmcblk0p1 /mnt/sd
ls /mnt/sd
umount /mnt/sd
```

For an unpartitioned FAT32 card, use `/dev/mmcblk0` for the mount instead.
Identify existing filesystems with `busybox blkid /dev/mmcblk0p1 /dev/mmcblk0p2`.
Use `-t exfat -o ro` for exFAT. For an existing Linux/ext4 root partition, set
it read-only with `sdcheck` and mount with **`-t ext4 -o ro,noload`**: `noload`
prevents journal replay, which a plain read-only ext4 mount can otherwise try.

For example, when partition 2 is ext4:

```sh
sdcheck /dev/mmcblk0p2
mount -t ext4 -o ro,noload /dev/mmcblk0p2 /mnt/sd
cat /mnt/sd/usr/lib/os-release
umount /mnt/sd
```

OS metadata and Raspberry Pi firmware filenames can identify an existing OS.
Do not execute scripts from an unknown card. Partition numbers and filesystem
types must be determined from the actual card, not assumed from this example.
`sdcheck` sets the whole block device and chosen partition read-only, verifies
the setting, reads exactly one sector and prints its SHA256. The temporary
sample is on the initramfs, not on the card. It neither formats nor repairs
media. Read-only state is a Linux block-device setting, not a hardware write
filter; it must be set again after a reboot/reinsert. Do not use a writable
mount or raw writes during this first check.

No card-detect input is wired: Linux polls for cards. Remove cards only after
unmounting and stopping accesses. The board cannot power-cycle a card; after
an interrupted protocol session a board power cycle may be needed.

## Tests

```sh
bash tools/test-sd-spi.sh
bash tools/test-de0cv-soc-sim.sh
```

The first runs the SPI host directly and through the shared GPIO/video/SPI
MMIO wrapper. It tests all 256 full-duplex byte values, SDHC initialization
responses and a patterned CMD17 sector with CRC16, CS-high clocks, byte lanes,
partial stores, a held request and reset. The card fixture is a test model,
not SD protocol compliance certification or physical-card evidence.
The full board simulation also issues CPU 32-bit MMIO transfers with CS high,
checks RX completion/read-to-clear and retains SDRAM/GPIO/VGA/timer checks.
Physical-card and filesystem results must be reported separately.
