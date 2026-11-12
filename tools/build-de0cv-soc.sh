#!/usr/bin/env bash
# Quartus build of the DE0-CV SoC (fpga/de0-cv/soc/rtl/de0cv_soc_top.sv):
# MiNTs CPU (board profile) + SDRAM path + JTAG loader + physical UART.
# Pins/IO/board models come from the verified SDRAM and UART echo projects.
# Output: build/fpga/de0cv-soc/ (previous output archived). Never programs.
#   STAGE=map  : Analysis & Synthesis only
#   STAGE=fit  : + Fitter + timing (default)
#   STAGE=asm  : + Assembler (SOF for SRAM programming)
#   FITTER_ROUTABILITY=ALWAYS: enable aggressive routing optimizations;
#     default AUTOMATICALLY preserves the baseline Fitter settings.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
stage=${STAGE:-fit}
routability=${FITTER_ROUTABILITY:-AUTOMATICALLY}
case "$routability" in
  AUTOMATICALLY|ALWAYS) ;;
  *) echo 'FITTER_ROUTABILITY must be AUTOMATICALLY or ALWAYS' >&2; exit 2 ;;
esac
cache_lines=${SOC_CACHE_LINES:-32}
[[ $cache_lines =~ ^[0-9]+$ ]] && (( cache_lines >= 2 && (cache_lines & (cache_lines - 1)) == 0 )) || {
  echo 'SOC_CACHE_LINES must be a power of two >= 2' >&2; exit 2;
}
[[ $stage == map || $stage == fit || $stage == asm ]] || { echo "STAGE must be map, fit or asm"; exit 2; }
out=build/fpga/de0cv-soc
if [[ -e "$out" ]]; then
  mkdir -p build/fpga/archive
  mv "$out" "build/fpga/archive/de0cv-soc-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out/rtl" "$out/quartus"
printf 'FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION=%s\n' "$routability" > "$out/fitter-options.txt"

# Boot ROM for the 64 MiB profile (a0 = hart 0, a1 = DTB, jump to RAM base).
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  make -s linux-bootrom-build PLATFORM_PROFILE=de0cv64 > "$out/bootrom-build.log" 2>&1
cp build/platform/de0cv64/bootrom_linux.hex "$out/quartus/bootrom_linux.hex"

files=$( { sed '/^#/d;/^$/d' core.f; cat <<'EOF'
rtl/peripheral/uart16550_regs.sv
fpga/de0-cv/rtl/uart_baud_gen.sv
fpga/de0-cv/rtl/uart_tx.sv
fpga/de0-cv/rtl/uart_rx.sv
fpga/de0-cv/rtl/uart_phy.sv
rtl/peripheral/uart16550_serial.sv
rtl/bus/membus_sdram_adapter.sv
fpga/de0-cv/sdram/rtl/sdram_bridge64.sv
fpga/de0-cv/sdram/rtl/sdram_native16.sv
fpga/de0-cv/sdram/rtl/sdram_board_pll.sv
fpga/de0-cv/rtl/boot_memory_loader.sv
fpga/de0-cv/rtl/jtag_block_mailbox.sv
fpga/de0-cv/soc/rtl/de0cv_soc_core.sv
fpga/de0-cv/soc/rtl/de0cv_soc_top.sv
EOF
} )
for f in $files; do cp "$f" "$out/rtl/"; done
(cd "$out/rtl" && shasum -a 256 *.sv) > "$out/sources.sha256"
shasum -a 256 "$out/quartus/bootrom_linux.hex" >> "$out/sources.sha256"

profile=(
  "SYNTHESIS=1" "SVCPU_RAM_EXTERNAL=1" "SVCPU_PHYSICAL_UART=1" "SVCPU_RAM_SIZE_BYTES=67108864"
  "SVCPU_SOC_CACHE_LINES=$cache_lines"
  "SVCPU_BP_PHT_ENTRIES=32" "SVCPU_BP_BTB_ENTRIES=${BP_BTB_ENTRIES:-4}" "SVCPU_BP_RAS_ENTRIES=4"
  "SVCPU_BP_ENABLE=${BP_ENABLE:-1}"
  "SVCPU_TLB_ENTRIES=${TLB_ENTRIES:-4}"
  "SVCPU_PMP_CARRY_COMPARE=${PMP_CARRY_COMPARE:-1}"
)
printf '%s\n' "${profile[@]}" "PERF=${PERF:-0}" > "$out/profile.txt"
sdram_qsf=fpga/de0-cv/sdram/quartus/de0_cv_sdram_test.qsf
{
  echo 'set_global_assignment -name FAMILY "Cyclone V"'
  echo 'set_global_assignment -name DEVICE 5CEBA4F23C7'
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY de0cv_soc_top'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1'
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"'
  echo 'set_global_assignment -name SDC_FILE de0cv_soc.sdc'
  if [[ $routability == ALWAYS ]]; then
    echo 'set_global_assignment -name FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS'
  fi
  # PERF=1: aggressive timing-driven (does NOT fit: 109 % ALM); default 0: synthesis/fit for the 20 MHz CPU clock.
  if [[ ${PERF:-0} == 1 ]]; then
    echo 'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE PERFORMANCE"'
    echo 'set_global_assignment -name ALLOW_REGISTER_RETIMING ON'
    echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC ON'
    echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION ON'
    echo 'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON'
    echo 'set_global_assignment -name FITTER_EFFORT "STANDARD FIT"'
  fi
  for m in "${profile[@]}"; do echo "set_global_assignment -name VERILOG_MACRO \"$m\""; done
  for f in $files; do echo "set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/$(basename "$f")"; done
  # SDRAM, clock and LED pins/IO/board models of the verified SDRAM test.
  grep -E '^set_(location|instance)_assignment' "$sdram_qsf" | grep -vE 'KEY0_N|key_meta|key_sync'
  echo 'set_location_assignment PIN_K22 -to UART_TXD'
  echo 'set_location_assignment PIN_M21 -to UART_RXD'
  echo 'set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to UART_TXD'
  echo 'set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to UART_RXD'
  echo 'set_instance_assignment -name WEAK_PULL_UP_RESISTOR ON -to UART_RXD'
  echo 'set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS" -to "de0cv_soc_core:soc|rxd_meta"'
  echo 'set_instance_assignment -name SYNCHRONIZER_IDENTIFICATION "FORCED IF ASYNCHRONOUS" -to "de0cv_soc_core:soc|rxd_sync"'
} > "$out/quartus/de0cv_soc.qsf"
echo 'PROJECT_REVISION = "de0cv_soc"' > "$out/quartus/de0cv_soc.qpf"
{
  grep -vE 'KEY0_N|set_clock_groups|^# JTAG status|^# crosses back' fpga/de0-cv/sdram/quartus/de0_cv_sdram_test.sdc
  echo 'set_false_path -from [get_ports {UART_RXD}]'
  echo 'set_false_path -to [get_ports {UART_TXD}]'
  echo '# JTAG mailbox: req/ack toggles cross through two-flop synchronizers;'
  echo '# command, buffers and results are only read while the handshake holds'
  echo '# them stable (see jtag_block_mailbox.sv).'
  echo 'set_clock_groups -asynchronous -group [get_clocks {CLOCK_50 *u_pll*}] -group [get_clocks {altera_reserved_tck}]'
} > "$out/quartus/de0cv_soc.sdc"

q=/opt/intelFPGA_lite/20.1/quartus/bin
steps="$q/quartus_map de0cv_soc > map.log 2>&1"
# Quartus 20.1 may truncate an unsized hexadecimal literal to 32 bits even
# inside a UIntX cast. Such a warning changes CSR masks and must block a build.
steps+=" && if grep -n 'Warning (10229)' map.log; then echo 'FAIL: truncated HDL literal'; exit 1; fi"
[[ $stage != map ]] && steps+=" && $q/quartus_fit de0cv_soc > fit.log 2>&1 && $q/quartus_sta de0cv_soc > sta.log 2>&1"
[[ $stage == asm ]] && steps+=" && $q/quartus_asm de0cv_soc > asm.log 2>&1"
rc=0
docker run --rm --init --name de0cv-soc-build --platform linux/amd64 \
  -v "${QUARTUS_VOLUME:-mints-quartus-20.1}:/opt/intelFPGA_lite" -v "$PWD/$out:/work" -w /work/quartus \
  -e LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1 "${QUARTUS_IMAGE:-mints-quartus:20.1}" \
  bash -c "$steps" || rc=$?
r=$out/quartus/output_files
{
  echo "stage=$stage rc=$rc"; cat "$out/profile.txt"
  cat "$out/fitter-options.txt"
  grep -E "Estimate of Logic utilization|Dedicated logic registers|Total block memory bits" "$r/de0cv_soc.map.rpt" 2>/dev/null | sed 's/^; */map: /' || true
  grep -E "Fitter Status|Logic utilization|Total registers|Total block memory bits|Total RAM Blocks|Total pins|Total PLLs" "$r/de0cv_soc.fit.summary" 2>/dev/null | sed 's/^/fit: /' || true
  grep -E "^; (Slow|Fast).*; [-0-9.]+ +;" "$r/de0cv_soc.sta.rpt" 2>/dev/null | head -20 | sed 's/^/sta: /' || true
  grep -hE "^Error" "$out"/quartus/*.log 2>/dev/null | head -20 || true
  ignored=$(python3 tools/check-quartus-assignments.py --allow-missing --count "$r/de0cv_soc.map.rpt" "$r/de0cv_soc.fit.rpt")
  echo "ignored_assignments=$ignored"
} > "$out/summary.txt"
awk '/; Analysis & Synthesis Resource Utilization by Entity/{f=1;next} f&&/Analysis & Synthesis RAM Summary/{exit} f&&/^; +\|/' \
  "$r/de0cv_soc.map.rpt" 2>/dev/null > "$out/by_entity.txt" || true
cat "$out/summary.txt"
if [[ $rc == 0 && $stage == asm ]]; then bash tools/signoff-de0cv-soc.sh || rc=$?; fi
exit $rc
