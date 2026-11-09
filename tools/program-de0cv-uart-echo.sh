#!/usr/bin/env bash
# Volatile FPGA configuration only (SRAM). This script never requests a flash write.
# Refuses to run until the GPIO bank voltage (3.3-V LVTTL on JP1) has been
# confirmed against a primary source (UART_BOARD_ECHO_DESIGN.md section 4).
# Once confirmed, the evidence is recorded in
# fpga/de0-cv/uart_echo/GPIO_VOLTAGE_EVIDENCE.md and the script runs normally;
# no further per-run approval is needed. CONFIRM_GPIO_3V3=yes is an explicit
# override for a reviewed session before that file exists.
set -euo pipefail
cd "$(dirname "$0")/.."
evidence=fpga/de0-cv/uart_echo/GPIO_VOLTAGE_EVIDENCE.md
if [[ ! -s "$evidence" && "${CONFIRM_GPIO_3V3:-}" != yes ]]; then
  echo "Refusing to program: GPIO 3.3 V not yet confirmed (missing $evidence;" >&2
  echo 'see fpga/de0-cv/UART_BOARD_ECHO_DESIGN.md section 4).' >&2
  exit 1
fi
: "${OPENFPGALOADER:=$PWD/local/fpga-tools/bin/openFPGALoader}"
q="$PWD/build/fpga/de0-cv-uart-echo/quartus"
rbf="$q/output_files/de0_cv_uart_echo.rbf"
[[ -s "$rbf" ]] || { echo "Build first: missing $rbf" >&2; exit 1; }
grep -q 'check_constraints: all checks passed' "$q/check_constraints.log" || {
  echo 'Constraint audit did not pass; refusing to configure.' >&2; exit 1;
}
mkdir -p build/logs
"$OPENFPGALOADER" --detect -c usb-blaster | tee build/logs/de0cv-jtag.log
grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-jtag.log || {
  echo 'Expected Cyclone V A4 IDCODE was not found; refusing to configure.' >&2; exit 1;
}
"$OPENFPGALOADER" --write-sram -c usb-blaster "$rbf"
echo 'Press and release KEY0. Expect LEDR9 on and LEDR0 blinking (1 Hz), LEDR3/4/5 off.'
