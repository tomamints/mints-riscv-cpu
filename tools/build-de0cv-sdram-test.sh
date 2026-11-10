#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QUARTUS_SH:=quartus_sh}"
: "${SDRAM_CLK_HZ:=50000000}"
case "$SDRAM_CLK_HZ" in
  20000000|50000000) ;;
  *) echo "Unsupported SDRAM clock profile: $SDRAM_CLK_HZ" >&2; exit 1;;
esac
qbin="$(dirname "$(command -v "$QUARTUS_SH")")"
root="$PWD"
out="$root/build/fpga/de0-cv-sdram-test"
if [[ -e "$out" ]]; then
  mkdir -p build/fpga/archive
  mv "$out" "build/fpga/archive/de0-cv-sdram-test-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out/rtl" "$out/quartus"
sha256sum fpga/de0-cv/sdram/rtl/*.sv fpga/de0-cv/sdram/quartus/* \
  tools/check-de0cv-sdram-pins.sh tools/build-de0cv-sdram-test.sh \
  > "$out/source-sha256.txt"
cp fpga/de0-cv/sdram/rtl/*.sv "$out/rtl/"
cp fpga/de0-cv/sdram/quartus/* "$out/quartus/"
printf "set_parameter -name CLK_HZ %s\n" "$SDRAM_CLK_HZ" >> "$out/quartus/de0_cv_sdram_test.qsf"
printf "SDRAM_CLK_HZ=%s\n" "$SDRAM_CLK_HZ" > "$out/build-config.txt"
cd "$out/quartus"
"$QUARTUS_SH" --flow compile de0_cv_sdram_test
if grep -nE 'Critical Warning|Ignored assignment' output_files/*.rpt; then
  echo 'Refusing image with critical warnings or ignored assignments.' >&2
  exit 1
fi
bash "$root/tools/check-de0cv-sdram-pins.sh" output_files/de0_cv_sdram_test.pin
"$qbin/quartus_sta" -t check_constraints.tcl | tee check_constraints.log
(cd "$root" && sha256sum -c "$out/source-sha256.txt")
"$qbin/quartus_cpf" -c output_files/de0_cv_sdram_test.sof output_files/de0_cv_sdram_test.rbf
sha256sum output_files/de0_cv_sdram_test.{sof,rbf} | tee output_files/sha256.txt
