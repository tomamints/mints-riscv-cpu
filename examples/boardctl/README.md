# DE0-CV GPIO control from Linux

`boardctl` accesses the board-only MMIO register through Linux UIO. It needs the
GPIO-enabled FPGA image and the `de0cv64` kernel/DTB with UIO enabled. It does not
use `/dev/mem` and does not require a custom kernel driver.

From the Linux shell:

```sh
boardctl status
boardctl self-test
boardctl leds 0x155
boardctl diagnostics
life --board 40
```

`leds` accepts a mask from 0 to 1023 and selects application LED ownership.
`diagnostics` returns ownership to the normal heartbeat/loader/fault display.
`status` reports synchronized switches, pressed keys, requested LED bits and
ownership. Readback is the requested LED register, not an optical measurement;
sticky fault LEDs 5–8 are forced on even in application mode.

Use one GPIO client at a time; there is no interprocess ownership lock.

The self-test temporarily writes several LED masks, checks readback and restores
the previous control value. Life's board mode also restores the previous value
on normal completion or SIGINT/SIGTERM. An uncatchable kill or crash can leave
application ownership active; run `boardctl diagnostics` to restore it.

## Life board mode

- SW0 = 1 pauses; SW0 = 0 resumes.
- KEY0 resets the world and displayed generation to zero. It does not reset Linux.
- LEDs show the generation modulo 1024, subject to the sticky fault overlay.
- `--board N` stops after N generation updates in total, even if the world is reset.
- Inputs are polled about every 20 ms plus processing time. KEY0 must be stable
  for two polling intervals; very short taps can be missed. Other switches/keys
  are available through `boardctl status` but do not control Life.

The hardware has two-stage input synchronizers and no interrupt/debounce logic.
Button filtering is performed by the application. [Life's non-board demo and
benchmark](../life/README.md) do not access GPIO.

## UIO mapping and register

The DTS registers `mints,de0cv-gpio` at `0x40000000`, with `linux,uio-name` set to
`mints-gpio`. The built-in `uio_pdrv_genirq` driver is selected by the board
boot argument `uio_pdrv_genirq.of_id=mints,de0cv-gpio`; there is no GPIO IRQ.
`/sys/class/uio/uio0/name` should report `mints-gpio` in this configuration.

Clients open `/dev/uio0` by default. Set `MINTS_GPIO_DEVICE` to select another
UIO device if numbering changes. A hardware ID check rejects an incompatible
register before writing it.

Only the first aligned eight-byte register is implemented. UIO maps a 4 KiB
page for alignment; other offsets in that mapping are not GPIO registers and
must not be accessed. The register replaces the simulator debug window only
when `SVCPU_BOARD_GPIO=1`. Generic simulation retains its printf/exit interface;
the separate read-only JTAG CPU snapshot is unchanged.

| Bits | Read | Write |
|---|---|---|
| 9:0 | Requested application LEDs | LED values |
| 10 | Application ownership | 1 = application, 0 = diagnostics |
| 15:11 | Zero | Ignored |
| 25:16 | SW9..SW0, synchronized | Ignored |
| 31:26 | Zero | Ignored |
| 35:32 | KEY3..KEY0, active high when pressed | Ignored |
| 47:36 | Zero | Ignored |
| 63:48 | Hardware ID `0x4d47` | Ignored |

Writes honor byte enables for bytes 0/1 only. The supplied clients use a 16-bit
control store and a 64-bit status load with ordering barriers.

Physical pins are recorded in `fpga/de0-cv/soc/gpio-pins.txt`, from tables 3-2
and 3-3 of the [Terasic DE0-CV manual](https://mm.digikey.com/Volume0/opasdata/d220001/medias/docus/5740/DE0_CV_User_Manual_112.pdf).
User buttons are inputs, not cold-reset sources. Existing SRAM/SDRAM programming
and UART wiring are unchanged.

## Build and tests

The standard board kernel rebuild builds both `/bin/life` and `/bin/boardctl`.
GPIO hardware changes additionally require a new FPGA synthesis/fit/signoff.
Follow the [board guide](../../fpga/de0-cv/soc/README.md).

```sh
python3 tools/test-board-apps.py
bash tools/test-board-gpio.sh
bash tools/test-de0cv-soc-sim.sh
```

The native client test uses a file-backed register for ownership, ID rejection,
pause/resume/reset and signal cleanup. The RTL unit test checks all byte masks,
read-only fields, synchronization latency and reset/response behavior. The
board-path simulation exercises CPU MMIO access alongside the JTAG/SDRAM path.
These tests are separate from fitted timing and physical switch/LED validation.
