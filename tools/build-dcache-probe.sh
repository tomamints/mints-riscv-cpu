#!/usr/bin/env bash
# dcache resource probe (analysis only: map + fit + sta, no assembler).
# Compares the original dcache of HEAD e9f95e7 (copied to
# build/baseline/dcache-e9f95e7/dcache.sv with its SHA-256) with the candidate
# rtl/cache/dcache.sv (DATA_RAM_STYLE 0 and 1) under the same wrapper/settings.
# Runs inside the Quartus container (see tools/build-dcache-probe-docker.sh).
# Output: build/fpga/dcache-probe/<cfg>/, summary in build/fpga/dcache-probe/summary.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QUARTUS_SH:=quartus_sh}"
qbin="$(dirname "$QUARTUS_SH")/"
[[ "$QUARTUS_SH" == quartus_sh ]] && qbin=""
baseline=build/baseline/dcache-e9f95e7/dcache.sv
expected_sha=04cdb211a3f1d19fd28ca8da164a3c88573c998e3979447e69e853bc4a22c86b
[[ -s "$baseline" ]] || { echo "missing $baseline (git show e9f95e7:rtl/cache/dcache.sv > $baseline)" >&2; exit 1; }
got_sha=$(sha256sum "$baseline" | awk '{print $1}')
[[ "$got_sha" == "$expected_sha" ]] || { echo "baseline hash mismatch: $got_sha" >&2; exit 1; }

root="$PWD/build/fpga/dcache-probe"
if [[ -e "$root" ]]; then
  mkdir -p "$PWD/build/fpga/archive"
  mv "$root" "$PWD/build/fpga/archive/dcache-probe-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$root"
summary="$root/summary.txt"
: > "$summary"
overall=0

#   name               source     LINES SBD STYLE
configs='base_l128_sb4      baseline  128   4   0
base_l32_sb4       baseline  32    4   0
cand_s0_l128_sb4   candidate 128   4   0
cand_s1_l128_sb4   candidate 128   4   1
cand_s1_l32_sb4    candidate 32    4   1'

while read -r name src lines sbd style; do
  # configuration pre-check: the wrapper fixes WRITE_BACK=0; style must be 0/1
  # and only the candidate source has the DATA_RAM_STYLE parameter.
  if [[ "$style" != 0 && "$style" != 1 ]] || [[ "$src" == baseline && "$style" != 0 ]]; then
    echo "REJECT $name: unsupported configuration" | tee -a "$summary"; overall=1; continue
  fi
  d="$root/$name"
  mkdir -p "$d/rtl" "$d/quartus"
  cp src/eei.sv src/core_data_if.sv fpga/de0-cv/cache_probe/rtl/dcache_probe_top.sv "$d/rtl/"
  if [[ $src == baseline ]]; then
    cp "$baseline" "$d/rtl/dcache.sv"
  else
    cp rtl/cache/dcache.sv fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv "$d/rtl/"
  fi
  cp fpga/de0-cv/cache_probe/quartus/dcache_probe.{qpf,qsf,sdc} "$d/quartus/"
  # Synthesis-only transform of the COPY (baseline and candidate alike): Quartus
  # 20.1 rejects the simulation-only "final" block (PERF_SUMMARY $display). It is
  # wrapped in synthesis translate_off/on; no other change. The originals are not
  # modified; the diff is kept in $d/synth_transform.diff.
  # Second copy-only transform (value-preserving syntax compatibility, approved):
  # Quartus 20.1 rejects 32-bit integer literals as values of the 64-bit
  # "typedef enum UIntX { ... } CsrCause" in eei.sv (Error 10355). Inside that
  # enum only, "= <dec>" -> "= 64'd<dec>" and "= 'h..." -> "= 64'h...". Values,
  # signs and order are unchanged (checked numerically on the host afterwards
  # by tools/check-dcache-probe-transforms.py). src/eei.sv itself is unchanged.
  cp "$d/rtl/eei.sv" "$d/eei.sv.orig"
  awk '
    /typedef enum UIntX *\{/ { inenum=1 }
    inenum && /=/ {
      if (match($0, /= *[0-9]+/)) { v=substr($0, RSTART, RLENGTH); sub(/= */, "", v); sub(/= *[0-9]+/, "= 64'"'"'d" v) }
      else sub(/= *'"'"'h/, "= 64'"'"'h")
    }
    inenum && /\} *CsrCause/ { inenum=0 }
    { print }
  ' "$d/eei.sv.orig" > "$d/rtl/eei.sv"
  diff -u "$d/eei.sv.orig" "$d/rtl/eei.sv" > "$d/synth_transform_eei.diff" || true
  if [[ $(grep -c "^+[^+]" "$d/synth_transform_eei.diff") -ne 19 ]] || [[ $(grep -c "^-[^-]" "$d/synth_transform_eei.diff") -ne 19 ]]; then
    echo "FAIL $name: eei.sv transform does not change exactly the 19 CsrCause lines" | tee -a "$summary"; overall=1; continue
  fi
  cp "$d/rtl/dcache.sv" "$d/dcache.sv.orig"
  awk '
    /^\tfinal begin$/ && !done { print "\t// synthesis translate_off"; infinal=1 }
    { print }
    infinal && /^\tend$/ { print "\t// synthesis translate_on"; infinal=0; done=1 }
  ' "$d/dcache.sv.orig" > "$d/rtl/dcache.sv"
  diff -u "$d/dcache.sv.orig" "$d/rtl/dcache.sv" > "$d/synth_transform.diff" || true
  if [[ $(grep -c "^+" "$d/synth_transform.diff") -ne 3 ]] || grep -q "^-[^-]" "$d/synth_transform.diff"; then
    echo "FAIL $name: synthesis transform is not exactly the final-block wrap" | tee -a "$summary"; overall=1; continue
  fi
  {
    for f in "$d"/rtl/*.sv; do
      echo "set_global_assignment -name SYSTEMVERILOG_FILE ../rtl/$(basename "$f")"
    done
    [[ $src == candidate ]] && echo 'set_global_assignment -name VERILOG_MACRO "DCACHE_HAS_DATA_RAM_STYLE=1"'
    echo "set_parameter -name LINE_COUNT $lines"
    echo "set_parameter -name STORE_BUFFER_DEPTH $sbd"
    echo "set_parameter -name DATA_RAM_STYLE $style"
  } >> "$d/quartus/dcache_probe.qsf"
  sha256sum "$d"/rtl/*.sv > "$d/sources.sha256"
  (
    cd "$d/quartus"
    "${qbin}quartus_map" dcache_probe > map.log 2>&1 &&
    "${qbin}quartus_fit" dcache_probe > fit.log 2>&1 &&
    "${qbin}quartus_sta" dcache_probe > sta.log 2>&1
  ) || { echo "FAIL $name: Quartus flow error (see $d/quartus/*.log)" | tee -a "$summary"; overall=1; continue; }
  q="$d/quartus/output_files"
  alms=$(awk -F';' '/Logic utilization \(in ALMs\)/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/dcache_probe.fit.rpt")
  regs=$(awk -F';' '/^; Total registers/{gsub(/ /,"",$3); print $3; exit}' "$q/dcache_probe.fit.rpt")
  bits=$(awk -F';' '/^; Total block memory bits/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/dcache_probe.fit.rpt")
  blocks=$(awk -F';' '/^; Total RAM Blocks/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/dcache_probe.fit.rpt")
  fmax=$(awk -F';' '/^; Slow 1100mV 85C Model Fmax Summary/{f=1; next} f && /No paths to report/{print "no-paths"; exit} f && /MHz/{gsub(/^ +| +$/,"",$2); print $2; exit}' "$q/dcache_probe.sta.rpt")
  ignored=$({ grep -cE "Critical Warning \(136021\)|Ignored assignment" "$q/dcache_probe.map.rpt" "$q/dcache_probe.fit.rpt" || true; } | awk -F: '{s+=$2} END{print s+0}')
  echo "$name src=$src lines=$lines sbd=$sbd style=$style | ALM=$alms regs=$regs blockbits=$bits ramblocks=$blocks fmax_slow85(probe-only)=$fmax ignored_assign=$ignored" | tee -a "$summary"
  awk '/^; Fitter Resource Utilization by Entity/{f=1} f&&/^$/{exit} f' "$q/dcache_probe.fit.rpt" > "$d/by_entity.txt" || true
  # RAM evidence: Fitter RAM Summary rows and the inferred altsyncram byte-enable parameters
  awk '/^; Fitter RAM Summary/{f=1} f&&/^$/{exit} f' "$q/dcache_probe.fit.rpt" > "$d/fitter_ram_summary.txt" || true
  { grep -E "WIDTH_BYTEENA_A|BYTE_SIZE|RAM_BLOCK_TYPE|NUMWORDS_A|WIDTH_A |OPERATION_MODE" "$q/dcache_probe.map.rpt" || true; } > "$d/logical_ram_params.txt"
  ramrows=$({ grep -cE "M10K block" "$d/fitter_ram_summary.txt" || true; })
  echo "  $name: fitter RAM rows (M10K)=$ramrows byteena8=$({ grep -c "WIDTH_BYTEENA_A *; 8" "$d/logical_ram_params.txt" || true; })" | tee -a "$summary"
  if [[ "$ignored" != 0 ]]; then
    echo "FAIL $name: ignored assignments ($ignored)" | tee -a "$summary"; overall=1
  fi
done <<< "$configs"
exit $overall
