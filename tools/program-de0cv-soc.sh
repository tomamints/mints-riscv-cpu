#!/usr/bin/env bash
# Volatile SRAM configuration of the signed-off DE0-CV SoC; never programs the
# configuration flash. The CPU stays held in reset until de0cv-jtag-load
# releases it.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${OPENFPGALOADER:=$PWD/local/fpga-tools/bin/openFPGALoader}"
out=${SOC_BUILD_DIR:-build/fpga/de0cv-soc}
r=$out/quartus/output_files
grep -q '^SIGNOFF PASS' "$out/signoff.txt" 2>/dev/null || { echo "Run tools/signoff-de0cv-soc.sh first" >&2; exit 1; }
(cd "$r" && shasum -a 256 -c sha256.txt)
grep -q "$(cd "$r" && shasum -a 256 de0cv_soc.rbf)" "$out/signoff.txt" || { echo "RBF differs from the signed-off image" >&2; exit 1; }
cat "$out/profile.txt"
mkdir -p build/logs
# USB-Blaster may need a second ID scan after a long idle interval.
if ! "$OPENFPGALOADER" --detect -c usb-blaster > build/logs/de0cv-soc-detect.log 2>&1 ||
   ! grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-soc-detect.log; then
  "$OPENFPGALOADER" --detect -c usb-blaster >> build/logs/de0cv-soc-detect.log 2>&1
fi
cat build/logs/de0cv-soc-detect.log
grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-soc-detect.log
"$OPENFPGALOADER" --write-sram -c usb-blaster "$r/de0cv_soc.rbf"
