# DE0-CV SoC: MiNTs CPU on SDRAM, loaded over JTAG

`rtl/de0cv_soc_top.sv` (PLL + virtual JTAG node) wraps `rtl/de0cv_soc_core.sv`:
MiNTs RV64IMAC CPU (board profile), 64 MiB SDRAM at 0x80000000 through
`membus_sdram_adapter` → `sdram_bridge64` → `sdram_native16`, ns16550 UART on
JP1 (TXD = JP1-8 / PIN_K22, RXD = JP1-10 / PIN_M21, 3.3 V, 115200 8N1), and a
JTAG block loader (`fpga/de0-cv/rtl/jtag_block_mailbox.sv` +
`boot_memory_loader.sv`). CPU, caches and SDRAM share one 20 MHz clock.

Board profile: I-cache/D-cache 32 lines (M10K data), D-cache write-through
with a 4-entry store buffer, branch predictor disabled (PHT 32 / BTB 4 / RAS 4 when enabled),
TLB 2 entries per side, and read-only JTAG CPU snapshots enabled.

## Boot sequence

1. Configuring the FPGA (SRAM) holds the CPU in reset. The SDRAM controller
   initializes after PLL lock (LEDR4).
2. `de0cv-jtag-load load IMAGE.hex` clears all 64 MiB (LEDR2), writes the
   image, reads every image word back and compares.
3. `de0cv-jtag-load release IMAGE.hex` reads back and compares again and only
   then releases the CPU (LEDR3). The CPU starts in the boot ROM, which jumps
   to 0x80000000 with a0 = 0 and a1 = DTB (0x83f00000).
4. Reloading needs a new FPGA configuration (there is no warm reset).

LEDR: 0 heartbeat, 1 PLL lock, 2 RAM cleared, 3 CPU running, 4 SDRAM init done,
5 memory fault, 6 loader fault, 7 UART TX overflow, 8 UART RX overrun,
9 CPU led[0].

## Commands

```sh
STAGE=asm bash tools/build-de0cv-soc.sh       # Quartus map/fit/STA/assembler + signoff
bash tools/signoff-de0cv-soc.sh               # (re)run signoff: STA all corners, pins, RBF
bash tools/program-de0cv-soc.sh               # SRAM configuration only (never flash)
bash tools/build-de0cv-jtag-load.sh           # native host loader (local/fpga-tools/bin)
bash tools/test-jtag-block-mailbox.sh         # mailbox + loader unit test
bash tools/test-de0cv-soc-sim.sh              # board-path simulation (JTAG load, run, UART)
bash tools/build-board-selftest.sh            # bare-metal self test images
```

Bare-metal self test on the board (UART banner, full SDRAM pattern test,
timer interrupts, then echo):

```sh
local/fpga-tools/bin/de0cv-jtag-load load    build/board/selftest/board_selftest.hex
local/fpga-tools/bin/de0cv-jtag-load release build/board/selftest/board_selftest.hex
```

Open the UART terminal (FTDI TTL-232R-3V3) before releasing, e.g.
`screen /dev/tty.usbserial-XXXX 115200`.

The loader refuses to run after a release, stops at the first error or
readback mismatch, and never releases without a complete verified readback.

## Linux (interactive BusyBox shell on ttyS0)

```sh
# From scratch (sources, toolchain, firmware, BusyBox, kernel and RAM image):
PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh all
# With dependencies already built, only rebuild the kernel and RAM image:
# PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh kernel
# PLATFORM_PROFILE=de0cv64 bash tools/rebuild-linux.sh image
bash tools/program-de0cv-soc.sh
local/fpga-tools/bin/de0cv-jtag-load load-run build/platform/de0cv64/opensbi_ram.hex
```

The board kernel uses `platform/linux_de0cv.fragment`: 100 Hz periodic
scheduler ticks with the normal `riscv_clocksource` hardware time source.
CPU and hardware timebase remain 20 MHz. There is no `clocksource=jiffies`
boot override. Kernel build directories and images have a `-de0cv64` suffix
to keep them separate from the simulator profile.

Timing signoff (20 MHz): setup slack +3.681 ns at the slow 85 C corner; every
corner's setup/hold/recovery/removal checks pass.
