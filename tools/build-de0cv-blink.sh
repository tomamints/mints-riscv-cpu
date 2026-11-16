#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QUARTUS_SH:=quartus_sh}"
command -v "$QUARTUS_SH" >/dev/null || {
  echo 'Quartus is required. Set QUARTUS_SH to the quartus_sh executable.' >&2
  exit 1
}
out="$PWD/build/fpga/de0-cv-blink"
mkdir -p "$out/rtl" "$out/quartus"
cp fpga/de0-cv/blink/rtl/de0_cv_blink.sv "$out/rtl/"
cp fpga/de0-cv/blink/quartus/de0_cv_blink.qpf \
   fpga/de0-cv/blink/quartus/de0_cv_blink.qsf \
   fpga/de0-cv/blink/quartus/de0_cv_blink.sdc "$out/quartus/"
cd "$out/quartus"
"$QUARTUS_SH" --flow compile de0_cv_blink
# openFPGALoader's Altera SRAM backend takes RBF, not SOF.
quartus_cpf="$(dirname "$QUARTUS_SH")/quartus_cpf"
if [[ "$QUARTUS_SH" == quartus_sh ]]; then quartus_cpf=quartus_cpf; fi
"$quartus_cpf" -c output_files/de0_cv_blink.sof output_files/de0_cv_blink.rbf
