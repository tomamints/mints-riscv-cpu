#!/usr/bin/env bash
# Independent fitted-pin check of the DE0-CV SoC against the board pin table
# (SDRAM, clock, LEDs as the SDRAM test; UART on JP1-8/JP1-10).
set -euo pipefail
script_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -s "$script_root/fpga/de0-cv/soc/gpio-pins.txt" ]] || { echo "PIN FAIL: GPIO pin manifest missing" >&2; exit 1; }
pinfile="$1"
fitfile="${pinfile%.pin}.fit.rpt"
count=0
while read -r name location direction; do
  actual=$(awk -F: -v n="$name" '{p=$1; gsub(/^ +| +$/,"",p)} p==n {for(i=2;i<=4;i++) {gsub(/^ +| +$/,"",$i)}; print $2 ":" $3 ":" $4; exit}' "$pinfile")
  standard="3.3-V LVCMOS"
  [[ "$name" == DRAM_* || "$name" == UART_* || "$name" == SW* || "$name" == KEY_N* ]] && standard="3.3-V LVTTL"
  expected="$location:$direction:$standard"
  [[ "$actual" == "$expected" ]] || {
    echo "PIN FAIL $name expected $expected, found $actual" >&2; exit 1;
  }
  if [[ "$name" == DRAM_* ]]; then
    fitted=$(awk -F';' -v n="$name" '{p=$2; gsub(/^ +| +$/,"",p)} p==n && /8mA/ && /3.3-V LVTTL/ {print; exit}' "$fitfile")
    [[ -n "$fitted" ]] || { echo "PIN FAIL $name: fitted 8mA LVTTL drive missing" >&2; exit 1; }
    if [[ "$name" == DRAM_DQ\[* ]]; then
      [[ "$fitted" == *'8 pF'* ]] || {
        echo "PIN FAIL $name: fitted 8pF load missing" >&2; exit 1;
      }
    fi
  fi
  count=$((count+1))
done < <(
cat <<'PINS'
CLOCK_50 M9 input
UART_TXD K22 output
UART_RXD M21 input
DRAM_ADDR[0] W8 output
DRAM_ADDR[1] T8 output
DRAM_ADDR[2] U11 output
DRAM_ADDR[3] Y10 output
DRAM_ADDR[4] N6 output
DRAM_ADDR[5] AB10 output
DRAM_ADDR[6] P12 output
DRAM_ADDR[7] P7 output
DRAM_ADDR[8] P8 output
DRAM_ADDR[9] R5 output
DRAM_ADDR[10] U8 output
DRAM_ADDR[11] P6 output
DRAM_ADDR[12] R7 output
DRAM_DQ[0] Y9 bidir
DRAM_DQ[1] T10 bidir
DRAM_DQ[2] R9 bidir
DRAM_DQ[3] Y11 bidir
DRAM_DQ[4] R10 bidir
DRAM_DQ[5] R11 bidir
DRAM_DQ[6] R12 bidir
DRAM_DQ[7] AA12 bidir
DRAM_DQ[8] AA9 bidir
DRAM_DQ[9] AB8 bidir
DRAM_DQ[10] AA8 bidir
DRAM_DQ[11] AA7 bidir
DRAM_DQ[12] V10 bidir
DRAM_DQ[13] V9 bidir
DRAM_DQ[14] U10 bidir
DRAM_DQ[15] T9 bidir
DRAM_BA[0] T7 output
DRAM_BA[1] AB7 output
LEDR[0] AA2 output
LEDR[1] AA1 output
LEDR[2] W2 output
LEDR[3] Y3 output
LEDR[4] N2 output
LEDR[5] N1 output
LEDR[6] U2 output
LEDR[7] U1 output
LEDR[8] L2 output
LEDR[9] L1 output
DRAM_CLK AB11 output
DRAM_CKE R6 output
DRAM_CS_N U6 output
DRAM_RAS_N AB6 output
DRAM_CAS_N V6 output
DRAM_WE_N AB5 output
DRAM_LDQM U12 output
DRAM_UDQM N8 output
PINS
cat "$script_root/fpga/de0-cv/soc/gpio-pins.txt"
)
[[ $count == 66 ]] || { echo "PIN FAIL: expected 66 checked pins, found $count" >&2; exit 1; }
echo "PIN PASS: $count board pins, location/direction/I/O standard"
