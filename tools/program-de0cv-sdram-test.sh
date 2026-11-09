#!/usr/bin/env bash
# Volatile SRAM configuration only; never programs configuration flash.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${OPENFPGALOADER:=$PWD/local/fpga-tools/bin/openFPGALoader}"
q="$PWD/build/fpga/de0-cv-sdram-test/quartus"
rbf="$q/output_files/de0_cv_sdram_test.rbf"
[[ -s "$rbf" ]] || { echo "Build first: missing $rbf" >&2; exit 1; }
grep -q 'check_constraints: all checks passed' "$q/check_constraints.log"
bash tools/check-de0cv-sdram-pins.sh "$q/output_files/de0_cv_sdram_test.pin"
(cd "$q" && shasum -a 256 -c output_files/sha256.txt)
mkdir -p build/logs
# USB-Blaster may need a second ID scan after a long idle interval.
if ! "$OPENFPGALOADER" --detect -c usb-blaster >build/logs/de0cv-sdram-detect.log 2>&1; then
  "$OPENFPGALOADER" --detect -c usb-blaster >>build/logs/de0cv-sdram-detect.log 2>&1
fi
cat build/logs/de0cv-sdram-detect.log
grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-sdram-detect.log
"$OPENFPGALOADER" --write-sram -c usb-blaster "$rbf"
