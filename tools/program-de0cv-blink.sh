#!/usr/bin/env bash
# Volatile FPGA configuration only. This script never requests a flash write.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${OPENFPGALOADER:=$PWD/local/fpga-tools/bin/openFPGALoader}"
sof="$PWD/build/fpga/de0-cv-blink/quartus/output_files/de0_cv_blink.sof"
[[ -s "$sof" ]] || { echo "Build the blink project first: missing $sof" >&2; exit 1; }
mkdir -p build/logs
"$OPENFPGALOADER" --detect -c usb-blaster | tee build/logs/de0cv-jtag.log
grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-jtag.log || {
  echo 'Expected Cyclone V A4 IDCODE was not found; refusing to configure.' >&2; exit 1;
}
"$OPENFPGALOADER" --write-sram -c usb-blaster "$sof"
echo 'Press and release KEY0, then check LEDR0 blinking every 0.5 seconds.'
