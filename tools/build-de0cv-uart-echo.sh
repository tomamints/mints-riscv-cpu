#!/usr/bin/env bash
# Compile the G3 UART echo project (inside the Quartus container, see the
# -docker wrapper), run the post-compile constraint audit, and make an RBF.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QUARTUS_SH:=quartus_sh}"
command -v "$QUARTUS_SH" >/dev/null || {
  echo 'Quartus is required. Set QUARTUS_SH to the quartus_sh executable.' >&2
  exit 1
}
qbin="$(dirname "$QUARTUS_SH")"
if [[ "$QUARTUS_SH" == quartus_sh ]]; then qbin=""; else qbin="$qbin/"; fi
out="$PWD/build/fpga/de0-cv-uart-echo"
# Keep the previous result (including failed runs) instead of deleting it.
if [[ -e "$out" ]]; then
  mkdir -p "$PWD/build/fpga/archive"
  mv "$out" "$PWD/build/fpga/archive/de0-cv-uart-echo-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out/rtl" "$out/quartus"
cp fpga/de0-cv/rtl/uart_baud_gen.sv fpga/de0-cv/rtl/uart_tx.sv \
   fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv \
   fpga/de0-cv/uart_echo/rtl/uart_echo_core.sv \
   fpga/de0-cv/uart_echo/rtl/de0_cv_uart_echo.sv "$out/rtl/"
cp fpga/de0-cv/uart_echo/quartus/de0_cv_uart_echo.qpf \
   fpga/de0-cv/uart_echo/quartus/de0_cv_uart_echo.qsf \
   fpga/de0-cv/uart_echo/quartus/de0_cv_uart_echo.sdc \
   fpga/de0-cv/uart_echo/quartus/check_constraints.tcl "$out/quartus/"
cd "$out/quartus"
"$QUARTUS_SH" --flow compile de0_cv_uart_echo

# Guard 1: no assignment may be ignored (e.g. invalid node names in the QSF).
if grep -nE 'Critical Warning \(136021\)|Ignored assignment' output_files/*.rpt; then
  echo 'FAIL: Quartus ignored one or more QSF assignments (see above).' >&2
  exit 1
fi

# Guard 2: every board pin must have the expected location, direction and
# I/O standard in the Pin-Out file (.pin columns: name : location : dir : std : ...).
pinfile=output_files/de0_cv_uart_echo.pin
expected='CLOCK_50 M9 input
KEY0_N U7 input
UART_RXD M21 input
UART_TXD K22 output
LEDR[0] AA2 output
LEDR[1] AA1 output
LEDR[2] W2 output
LEDR[3] Y3 output
LEDR[4] N2 output
LEDR[5] N1 output
LEDR[6] U2 output
LEDR[7] U1 output
LEDR[8] L2 output
LEDR[9] L1 output'
pin_fail=0
while read -r name loc dir; do
  row=$(awk -F: -v n="$name" '{g=$1; gsub(/^ +| +$/,"",g)} g==n {print; exit}' "$pinfile")
  got_loc=$(echo "$row" | awk -F: '{gsub(/ /,"",$2); print $2}')
  got_dir=$(echo "$row" | awk -F: '{gsub(/ /,"",$3); print $3}')
  got_std=$(echo "$row" | awk -F: '{s=$4; gsub(/^ +| +$/,"",s); print s}')
  if [[ "$got_loc" == "$loc" && "$got_dir" == "$dir" && "$got_std" == "3.3-V LVTTL" ]]; then
    echo "PIN OK   $name $got_loc $got_dir $got_std"
  else
    echo "PIN FAIL $name expected $loc $dir 3.3-V LVTTL, got '$got_loc' '$got_dir' '$got_std'" >&2
    pin_fail=1
  fi
done <<< "$expected"
[[ $pin_fail -eq 0 ]] || { echo 'FAIL: Pin-Out mismatch.' >&2; exit 1; }
# Post-compile audit: exact SDC collection counts, synchronizer stages still
# timed, worst setup/hold slack >= 0. Non-zero exit fails the build.
"${qbin}quartus_sta" -t check_constraints.tcl | tee check_constraints.log
"${qbin}quartus_cpf" -c output_files/de0_cv_uart_echo.sof output_files/de0_cv_uart_echo.rbf
sha256sum output_files/de0_cv_uart_echo.sof output_files/de0_cv_uart_echo.rbf | tee output_files/sha256.txt
