# G3: DE0-CV physical UART echo (no CPU, no SDRAM)

Design and review record: [`../UART_BOARD_ECHO_DESIGN.md`](../UART_BOARD_ECHO_DESIGN.md).
Status (2026-11-09): RTL lint and core/top simulations passed; Quartus Fit,
all-corner timing and constraint/pin audits passed. SRAM programming reached
100% / Done / exit 0. Physical UART echo is pending wiring and host testing.
GPIO 3.3 V evidence is recorded in [GPIO_VOLTAGE_EVIDENCE.md](GPIO_VOLTAGE_EVIDENCE.md).
A PASS here is a physical-layer echo PASS, not a 16550 or Linux UART PASS.

## What it does
- 115200 8N1 (CLOCK_50, REF 3.6864 MHz, divisor 2). Every correctly framed byte
  received on `UART_RXD` is sent back on `UART_TXD` through a 16-entry buffer.
- Framing errors and BREAK are not echoed; they light LEDR3 / LEDR4 (sticky).
  A dropped byte (buffer full) lights LEDR5 (sticky). KEY0 clears everything.
- LEDR0 heartbeat (1 Hz), LEDR1 RX activity, LEDR2 TX activity, LEDR9 reset released,
  LEDR6..8 off.

## Wiring (power off while wiring)
| JP1 pin | Signal | FPGA pin | USB-UART (3.3 V) |
|---|---|---|---|
| 8  | `UART_TXD` (FPGA output) | PIN_K22 (GPIO_0_D7) | RXD |
| 10 | `UART_RXD` (FPGA input, weak pull-up) | PIN_M21 (GPIO_0_D9) | TXD |
| 12 | GND | — | GND |

Do not connect pin 11 (VCC5) or the adapter's power wire.
Source: Terasic DE0-CV User Manual (2015-05-04), Figure 3-12 and Table 3-7.

## Flow (after review GO only)
```sh
bash tools/test-uart-echo-sim.sh                 # lint + core TB + board-top simulation
bash tools/build-de0cv-uart-echo-docker.sh       # Quartus compile + check_constraints.tcl + RBF
bash tools/program-de0cv-uart-echo.sh           # refuses until GPIO_VOLTAGE_EVIDENCE.md records the 3.3 V confirmation
bash tools/setup-uart-host-venv.sh               # once: build/venv-uart with pyserial==3.5
build/venv-uart/bin/python tools/uart_echo_test.py --port /dev/cu.<your-adapter> [--break-test]
```
`uart_echo_test.py` never picks a port by itself. Without `--port` it only lists the ports.

SRAM configuration is volatile: after powering the board off for wiring, run
`bash tools/program-de0cv-uart-echo.sh` again before testing.

Resource checkpoint: 227 ALMs, 270 registers, one M10K (128 bits).
Worst setup/hold slack across four corners: 11.845/0.146 ns at 50 MHz.
Unconstrained paths: zero; remaining warnings are classified in the design record.
