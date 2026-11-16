#!/usr/bin/env bash
# Volatile SRAM configuration only; never programs configuration flash.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${OPENFPGALOADER:=$PWD/local/fpga-tools/bin/openFPGALoader}"
q="$PWD/build/fpga/de0-cv-sdram-test/quartus"
rbf="$q/output_files/de0_cv_sdram_test.rbf"
[[ -s "$rbf" ]] || { echo "Build first: missing $rbf" >&2; exit 1; }
cat "$q/../build-config.txt"
profile_clock=$(awk -F= '$1=="SDRAM_CLK_HZ" {print $2}' "$q/../build-config.txt")
case "$profile_clock" in 20000000|50000000) ;; *) echo 'Invalid built clock profile' >&2; exit 1;; esac
awk -F';' -v hz="$profile_clock" '
  function abs(x) {return x<0 ? -x : x}
  {name=$2; gsub(/^ +| +$/,"",name)}
  name=="SDRAM_CLK" {
    external++; if(abs($4-1e9/hz)>0.001 || abs($6-1e9/hz/4)>0.001) bad=1
  }
  name ~ /generic_pll1~PLL_OUTPUT_COUNTER\|divclk$/ {
    controller++; if(abs($4-1e9/hz)>0.001 || abs($6)>0.001) bad=1
  }
  END {
    if(bad || external!=1 || controller!=1) {
      print "CLOCK FAIL: fitted clocks do not match the requested profile"; exit 1
    }
    print "CLOCK PASS: controller/forwarded clock match " hz " Hz"
  }
' "$q/check_constraints_clocks.rpt"
grep -q 'check_constraints: all checks passed' "$q/check_constraints.log"
shasum -a 256 -c "$q/../source-sha256.txt"
bash tools/check-de0cv-sdram-pins.sh "$q/output_files/de0_cv_sdram_test.pin"
(cd "$q" && shasum -a 256 -c output_files/sha256.txt)
mkdir -p build/logs
# USB-Blaster may need a second ID scan after a long idle interval.
if ! "$OPENFPGALOADER" --detect -c usb-blaster >build/logs/de0cv-sdram-detect.log 2>&1 ||
   ! grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-sdram-detect.log; then
  "$OPENFPGALOADER" --detect -c usb-blaster >>build/logs/de0cv-sdram-detect.log 2>&1
fi
cat build/logs/de0cv-sdram-detect.log
grep -Eq 'idcode 0x0?2b050dd([[:space:]]|$)' build/logs/de0cv-sdram-detect.log
"$OPENFPGALOADER" --write-sram -c usb-blaster "$rbf"
