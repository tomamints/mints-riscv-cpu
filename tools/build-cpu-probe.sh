#!/usr/bin/env bash
# Analysis-only Quartus Map+Fit of the CPU (fpga/de0-cv/cpu_probe) from the
# canonical sources listed in fpga/de0-cv/cpu_probe/cpu_probe.f.
# No assembler, no programming, no external timing claim (virtual pins).
# Profile parameters (defaults = compact board profile) can be overridden:
#   ICACHE_LINE_COUNT ICACHE_DATA_RAM_STYLE DCACHE_LINE_COUNT
#   DCACHE_STORE_BUFFER_DEPTH DCACHE_DATA_RAM_STYLE BP_PHT_ENTRIES BP_BTB_ENTRIES BP_RAS_ENTRIES
# Output: build/fpga/cpu-probe-$LABEL/ (previous output archived). Exit status
# is non-zero on a Map error, any ignored assignment, or a Fit failure.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
label=${LABEL:-compact}
out=build/fpga/cpu-probe-$label
if [[ -e "$out" ]]; then
  mkdir -p build/fpga/archive
  mv "$out" "build/fpga/archive/cpu-probe-$label-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out/rtl" "$out/quartus"
files=fpga/de0-cv/cpu_probe/cpu_probe.f
while read -r f; do [[ -n $f ]] && cp "$f" "$out/rtl/"; done < "$files"
(cd "$out/rtl" && shasum -a 256 *.sv) > "$out/sources.sha256"
{
  echo 'set_global_assignment -name FAMILY "Cyclone V"'
  echo 'set_global_assignment -name DEVICE 5CEBA4F23C7'
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY cpu_probe_top'
  echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 1'
  echo 'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files'
  echo 'set_global_assignment -name VERILOG_MACRO "SYNTHESIS=1"'
  echo 'set_global_assignment -name SDC_FILE cpu_probe.sdc'
  echo 'set_instance_assignment -name VIRTUAL_PIN ON -to v_*'
  while read -r f; do [[ -n $f ]] && echo "set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/$(basename "$f")"; done < "$files"
  for p in ICACHE_LINE_COUNT:32 ICACHE_DATA_RAM_STYLE:1 DCACHE_LINE_COUNT:32 DCACHE_STORE_BUFFER_DEPTH:4 \
           DCACHE_DATA_RAM_STYLE:1 BP_PHT_ENTRIES:32 BP_BTB_ENTRIES:8 BP_RAS_ENTRIES:4; do
    name=${p%%:*}; def=${p##*:}; val=${!name:-$def}
    echo "set_parameter -name $name $val"
    echo "$name=$val" >> "$out/profile.txt"
  done
} > "$out/quartus/cpu_probe.qsf"
echo 'PROJECT_REVISION = "cpu_probe"' > "$out/quartus/cpu_probe.qpf"
{
  echo 'create_clock -name clk -period 50.000 [get_ports {clk}]'
  echo 'set_false_path -from [get_ports {v_*}]'
  echo 'set_false_path -to [all_outputs]'
} > "$out/quartus/cpu_probe.sdc"
q=/opt/intelFPGA_lite/20.1/quartus/bin
rc=0
docker run --rm --init --name "cpu-probe-$label" --platform linux/amd64 \
  -v "${QUARTUS_VOLUME:-mints-quartus-20.1}:/opt/intelFPGA_lite" -v "$PWD/$out:/work" -w /work/quartus \
  -e LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1 "${QUARTUS_IMAGE:-mints-quartus:20.1}" \
  bash -c "$q/quartus_map cpu_probe > map.log 2>&1 && $q/quartus_fit cpu_probe > fit.log 2>&1" || rc=$?
r=$out/quartus/output_files
summary=$out/summary.txt
{
  echo "label=$label rc=$rc"; cat "$out/profile.txt"
  grep -E "Estimate of Logic utilization|Dedicated logic registers|Total block memory bits" "$r/cpu_probe.map.rpt" 2>/dev/null | sed 's/^; */map: /'
  grep -E "Fitter Status|Logic utilization|Total registers|Total block memory bits|Total RAM Blocks" "$r/cpu_probe.fit.summary" 2>/dev/null | sed 's/^/fit: /'
  ignored=$({ grep -cE "Critical Warning \(136021\)|Ignored assignment" "$r/cpu_probe.map.rpt" "$r/cpu_probe.fit.rpt" 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')
  echo "ignored_assignments=$ignored"
} > "$summary"
awk '/; Analysis & Synthesis Resource Utilization by Entity/{f=1;next} f&&/Analysis & Synthesis RAM Summary/{exit} f&&/^; +\|/' \
  "$r/cpu_probe.map.rpt" 2>/dev/null > "$out/by_entity.txt" || true
cat "$summary"
grep -q "^ignored_assignments=0$" "$summary" || rc=1
grep -q "Fitter Status : Successful" "$summary" || rc=1
exit $rc
