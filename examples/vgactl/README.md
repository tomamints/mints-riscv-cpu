# Linux applications on the VGA text screen

These commands require the VGA-enabled FPGA image and the `de0cv64` Linux image
with `vgactl`. Connect a VGA monitor to the board's VGA connector. UART remains
the Linux input/console path; a keyboard interface is not added by this feature.

From the Linux shell:

```sh
vgactl status
vgactl self-test
vgactl demo
life --vga 40
```

- `status` reports acknowledged page swaps and busy state.
- `self-test` presents a filled page and a text page and waits for acknowledgement.
  It checks the command/acknowledgement path, not optical pixel correctness.
- `demo` writes an example text screen from a Linux C program.
- `life --vga N` displays the world/generation, uses SW0 for pause/resume and
  KEY0 for reset, and shows the generation on the application LEDs.

Life restores the previous LED ownership on normal exit or SIGINT/SIGTERM.
The last video frame remains visible after the application exits. Commands
and checksum results remain on UART. The ordinary `life --demo`, `--board`
and `--bench` modes are retained.

The standard kernel rebuild builds and embeds `/bin/vgactl` alongside Life and
boardctl. New hardware is also required; use the
[board build/boot procedure](../../fpga/de0-cv/soc/README.md). Generic older GPIO
images are rejected by a feature-bit check before video-register access.

All clients share one UIO mapping and have no interprocess ownership lock.
Use one display writer at a time. Each update writes a full 80 × 30 back page
and waits for its vertical-blank acknowledgement, with a two-second software
timeout. A pending earlier swap is completed before a new update begins.

See [video timing, RAM and register details](../../fpga/de0-cv/vga/README.md).
