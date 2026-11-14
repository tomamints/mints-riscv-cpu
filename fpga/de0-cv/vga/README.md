# VGA text output

The board video engine renders an 80 × 30 text screen on the DE0-CV VGA
connector. It is an application-controlled text display, not a Linux framebuffer
console or desktop. UART remains the Linux console.

## Signal timing

| Item | Configuration |
|---|---|
| Engine clock | Existing `CLOCK_50`, 50 MHz |
| Pixel rate | One pixel every two engine clocks: 25 MHz |
| Active / total width | 640 / 800 pixels |
| Horizontal front porch / sync / back porch | 16 / 96 / 48 pixels |
| Active / total height | 480 / 525 lines |
| Vertical front porch / sync / back porch | 10 / 2 / 33 lines |
| Sync polarity | Negative HS and VS |
| Actual nominal refresh | 59.5238 Hz; horizontal rate 31.25 kHz |
| Color outputs | Four bits each for R/G/B |

This uses the 25 MHz profile described in the
[Terasic manual, tables 3-8 through 3-10](https://www.engr.newpaltz.edu/~bai/EGC221/DE0_CV_User_Manual_112.pdf).
It is not an exact 25.175 MHz timing source. Monitor/adapter compatibility must
be checked with the actual display. Pins are in `../soc/vga-pins.txt`.

No new clock divider output or PLL setting is introduced. A clock enable on the
50 MHz domain controls pixel updates; the CPU, timer and SDRAM remain at 20 MHz.
The board constraints give the VGA outputs a conservative source-clock budget
(`CLOCK_50`, max output delay 5 ns, min 0 ns, 6 pF assumed load). These are
board/display interface assumptions, not a modeled monitor capture clock or
measured cable/DAC characteristics. Internal clock paths and these output
budgets are checked at all corners.

## Memory and frame ownership

- Two 4096-byte text pages use synchronous dual-clock M10K RAM.
- The CPU writes the back page; video reads the front page.
- A commit toggle crosses two synchronizers and swaps the front page at the
  start of vertical blank. An acknowledgement crosses back to the CPU.
- Writes are blocked until the acknowledgement updates back-page ownership.
- The caller initializes all 2400 visible characters before each commit.
- Uninitialized text RAM is not displayed. A startup color pattern is emitted
  until the first page is presented.

The font is an original block-glyph bitmap in `font8x8.hex`. Its 1024 × 8 ROM
uses M10K; five-by-seven glyphs are vertically doubled in eight-by-sixteen cells.
Letters, digits and selected punctuation are supported; this is not a Unicode
terminal. `#` is green and other lit characters are white.

## Linux interface

The video registers share the existing GPIO UIO mapping. GPIO's status bit 47
advertises the extension, so new clients reject older GPIO-only FPGA images
before touching the additional registers.

| Byte offset | Read | Write |
|---|---|---|
| 0 | Existing GPIO status plus VGA feature bit | Existing GPIO control |
| 8 | Zero | Full 64-bit text/commit command |
| 16 | ID `0x5654` in bits 63:48, busy in bit 32, acknowledged commits in bits 31:0 | Ignored |
| 24 | Zero | Ignored |

Text commands have address bits 11:0 and ASCII bits 23:16. Bit 63 commits the
back page instead. Partial command writes are ignored; the clients use full
64-bit stores. The commit count counts page swaps, not automatic refreshes.
Other addresses in the page-aligned UIO mapping are not implemented registers.

See [Linux display commands](../../../examples/vgactl/README.md) and
[GPIO controls](../../../examples/boardctl/README.md).

## Verification tools

```sh
bash tools/test-vga-text.sh
bash tools/test-vga-mmio.sh
python3 tools/test-vga-clients.py
bash tools/test-de0cv-soc-sim.sh
```

The renderer test checks horizontal/vertical pulse lengths, blanking, frame
ownership and acknowledgements. Its captured frame is compared against an
independent reference for all 307,200 active pixels. The MMIO test covers reset,
backpressure, status, partial writes and GPIO access during video backpressure.
Native client tests check the old-hardware guard, a previously pending swap,
command encoding and the Life framebuffer layout. The board-path test runs CPU
MMIO commands through the real memory-system integration.

Timing/pin signoff and register acknowledgements on an FPGA do not replace
viewing the output on a connected monitor. Keep the distinction explicit when
reporting validation results.

## Validated board profile

The VGA-enabled SoC fits at 17,269 / 18,480 ALMs, 13,928 registers and 64 RAM
blocks (230,052 bits). All four timing corners pass setup, hold, recovery and
removal; worst setup slack is +2.168 ns. Pin signoff checks 84 board pins,
including all 14 VGA outputs. These results include the source-clock output
budget described above, not a measured monitor interface.

On the physical FPGA, Linux `vgactl self-test` passed, followed by demo and
`life --vga 4`. The latter produced the reference checksum `401a90e3423e2d3c`;
page acknowledgements advanced from 0 to 9 and busy returned to zero. GPIO
ownership was restored, the post-display benchmark checksum passed, and
`riscv_clocksource` and the UART shell remained operational. A connected
monitor image has not yet been observed.
