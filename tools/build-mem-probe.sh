#!/usr/bin/env bash
# RAM inference probe (analysis only: map + fit + sta, no assembler/bitstream).
# Runs inside the Quartus container (see tools/build-mem-probe-docker.sh).
# Each configuration is compiled in build/fpga/mem-probe/<cfg>/; a previous
# result is moved to build/fpga/archive/ instead of being deleted.
# Summary: build/fpga/mem-probe/summary.txt. Exit non-zero if a REQUIRED
# configuration is FAIL or UNVERIFIED (reference configurations only record).
# Byte enables are proven from two independent sources, never from a column's
# mere presence: (1) logical: map.rpt altsyncram parameters WIDTH_A=64,
# NUMWORDS_A=DEPTH, WIDTH_BYTEENA_A=8, BYTE_SIZE=8, one RAM per bank;
# (2) physical: post-fit netlist (quartus_eda .vo) cyclonev_ram_block atoms,
# all M10K, data widths covering 64 bits per bank, byte-enable parameters present.
# Missing evidence => UNVERIFIED (not PASS).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QUARTUS_SH:=quartus_sh}"
qbin="$(dirname "$QUARTUS_SH")/"
[[ "$QUARTUS_SH" == quartus_sh ]] && qbin=""
root="$PWD/build/fpga/mem-probe"
if [[ -e "$root" ]]; then
  mkdir -p "$PWD/build/fpga/archive"
  mv "$root" "$PWD/build/fpga/archive/mem-probe-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$root"
summary="$root/summary.txt"
: > "$summary"
overall=0

#   name            DEPTH NBANK STYLE ASYNC role
configs='p128x1_m10k     128 1 2 0 required
p128x4_m10k     128 4 2 0 required
p32x1_m10k      32  1 2 0 required
p32x1_auto      32  1 0 0 reference
p128x1_m10k_rw  128 1 1 0 reference
p128x1_async    128 1 2 1 reference
p32x1_async     32  1 2 1 reference'

while read -r name depth nbank style async role; do
  d="$root/$name"
  mkdir -p "$d/rtl" "$d/quartus"
  cp fpga/de0-cv/mem_probe/rtl/*.sv "$d/rtl/"
  cp fpga/de0-cv/mem_probe/quartus/mem_probe.{qpf,qsf,sdc} "$d/quartus/"
  {
    echo "set_parameter -name DEPTH $depth"
    echo "set_parameter -name NBANK $nbank"
    echo "set_parameter -name STYLE $style"
    echo "set_parameter -name ASYNC $async"
  } >> "$d/quartus/mem_probe.qsf"
  (
    cd "$d/quartus"
    "${qbin}quartus_map" mem_probe > map.log 2>&1 &&
    "${qbin}quartus_fit" mem_probe > fit.log 2>&1 &&
    "${qbin}quartus_sta" mem_probe > sta.log 2>&1 &&
    # Post-fit gate-level netlist: RAM atoms (cyclonev_ram_block) and their
    # parameters are the physical evidence for block count and byte enables.
    "${qbin}quartus_eda" mem_probe --simulation --tool=modelsim --format=verilog > eda.log 2>&1
  ) || { echo "FAIL $name: Quartus flow error (see $d/quartus/*.log)" | tee -a "$summary"; overall=1; continue; }

  q="$d/quartus/output_files"
  alms=$(awk -F';' '/Logic utilization \(in ALMs\)/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/mem_probe.fit.rpt")
  regs=$(awk -F';' '/^; Total registers/{gsub(/ /,"",$3); print $3; exit}' "$q/mem_probe.fit.rpt")
  bits=$(awk -F';' '/^; Total block memory bits/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/mem_probe.fit.rpt")
  blocks=$(awk -F';' '/^; Total RAM Blocks/{gsub(/^ +| +$/,"",$3); print $3; exit}' "$q/mem_probe.fit.rpt")
  # Slow 85C Fmax table; "No paths to report" when there is no register-to-register path.
  fmax=$(awk -F';' '/^; Slow 1100mV 85C Model Fmax Summary/{f=1; next} f && /No paths to report/{print "no-reg2reg-paths"; exit} f && /MHz/{gsub(/^ +| +$/,"",$2); print $2; exit}' "$q/mem_probe.sta.rpt")
  awk '/^; RAM Summary/{f=1} f&&/^$/{exit} f' "$q/mem_probe.map.rpt" > "$d/ram_summary.txt" || true
  awk '/^; Fitter RAM Summary/{f=1} f&&/^$/{exit} f' "$q/mem_probe.fit.rpt" > "$d/fit_ram_summary.txt" || true
  passthru=$(grep -c "Pass-through logic has been added" "$q/mem_probe.map.rpt" || true)
  uninferred=$(grep -ciE "uninferred|could not be inferred|not inferred" "$q/mem_probe.map.rpt" || true)
  # grep -c exits 1 on zero matches; keep pipefail from aborting the script.
  ignored=$({ grep -cE "Critical Warning \(136021\)|Ignored assignment" "$q/mem_probe.map.rpt" "$q/mem_probe.fit.rpt" || true; } | awk -F: '{s+=$2} END{print s+0}')

  # Logical evidence: map.rpt "Parameter Settings for Inferred Entity Instance:
  # ...|altsyncram:..." tables, one line per inferred RAM.
  awk -F';' '
    /^; Parameter Settings for Inferred Entity Instance:.*altsyncram/ { inst=$2; gsub(/^ +| +$/,"",inst); sub(/.*Instance: /,"",inst); n++; name[n]=inst; next }
    n && /^; [A-Z_]+ +;/ { k=$2; v=$3; gsub(/ /,"",k); gsub(/^ +| +$/,"",v); val[n,k]=v }
    END { for (i=1;i<=n;i++) printf "%s | OPERATION_MODE=%s WIDTH_A=%s NUMWORDS_A=%s WIDTH_B=%s NUMWORDS_B=%s WIDTH_BYTEENA_A=%s BYTE_SIZE=%s RAM_BLOCK_TYPE=%s RDW_MIXED=%s\n", name[i], val[i,"OPERATION_MODE"], val[i,"WIDTH_A"], val[i,"NUMWORDS_A"], val[i,"WIDTH_B"], val[i,"NUMWORDS_B"], val[i,"WIDTH_BYTEENA_A"], val[i,"BYTE_SIZE"], val[i,"RAM_BLOCK_TYPE"], val[i,"READ_DURING_WRITE_MODE_MIXED_PORTS"] }
  ' "$q/mem_probe.map.rpt" > "$d/logical_rams.txt"
  n_logical=$(wc -l < "$d/logical_rams.txt" | tr -d ' ')
  n_logical_ok=$(awk -v D="$depth" '/WIDTH_A=64 / && $0 ~ ("NUMWORDS_A=" D " ") && /WIDTH_BYTEENA_A=8 / && /BYTE_SIZE=8 / {c++} END{print c+0}' "$d/logical_rams.txt")

  # Physical evidence: cyclonev_ram_block atoms in the post-fit netlist (.vo):
  # one line per atom with its bank, data widths and byte-enable parameters.
  vo=$(ls "$d"/quartus/simulation/modelsim/*.vo 2>/dev/null | head -n1 || true)
  if [[ -n "$vo" ]]; then
    awk '
      /defparam/ && /ram_block/ {
        line=$0; sub(/^[^\\]*\\/,"",line); inst=line; sub(/ .*/,"",inst)
        key=line; sub(/^[^ ]* +\./,"",key); sub(/ *=.*/,"",key); gsub(/ /,"",key)   # escaped names contain dots; the key follows " ."
        v=line; sub(/^[^=]*= */,"",v); sub(/;.*/,"",v); gsub(/"/,"",v)
        p[inst,key]=v; seen[inst]=1
      }
      END {
        for (i in seen) {
          b=i; if (match(b,/g_bank\[[0-9]+\]/)) b=substr(b,RSTART,RLENGTH); else b="?"
          printf "%s | %s | type=%s mode=%s a_width=%s a_depth=%s b_width=%s a_byteena_width=%s a_byte_size=%s\n", b, i, p[i,"ram_block_type"], p[i,"operation_mode"], p[i,"port_a_data_width"], p[i,"port_a_first_address"]"-"p[i,"port_a_last_address"], p[i,"port_b_data_width"], p[i,"port_a_byte_enable_mask_width"], p[i,"port_a_byte_size"]
        }
      }' "$vo" | sort > "$d/physical_ram_atoms.txt"
  else
    : > "$d/physical_ram_atoms.txt"
  fi
  n_atoms=$(grep -c . "$d/physical_ram_atoms.txt" || true)
  # Note: the netlist atom parameter ram_block_type is a generic string (it reads
  # "M20K" on this Cyclone V netlist) and is NOT used as the block-type evidence.
  # Block type/count come from the Fitter RAM Summary (Type, M10K blocks, MLABs).
  awk -F';' '/^; Fitter RAM Summary/{f=1; next} f && /^$/ {exit}
    f && /altsyncram/ { n=$2; gsub(/^ +| +$/,"",n); t=$3; gsub(/^ +| +$/,"",t); m=$4; gsub(/^ +| +$/,"",m);
      sz=$14; gsub(/ /,"",sz); blk=$20; gsub(/ /,"",blk); mlab=$21; gsub(/ /,"",mlab); rdw=$24; gsub(/^ +| +$/,"",rdw);
      printf "%s | type=%s mode=%s size=%s m10k_blocks=%s mlabs=%s mixed_rdw=%s\n", n, t, m, sz, blk, mlab, rdw }' \
    "$q/mem_probe.fit.rpt" > "$d/fitter_rams.txt"
  n_fit_m10k=$(grep -c "type=M10K block mode=Simple Dual Port size=$((depth*64)) " "$d/fitter_rams.txt" || true)
  m10k_blocks=$(awk -F'm10k_blocks=' '{split($2,a," "); s+=a[1]} END{print s+0}' "$d/fitter_rams.txt")
  # Byte-enable wiring: for every RAM atom, the drivers of portabyteenamasks and
  # the wbe[] bits feeding each driver LUT (non-constant data inputs).
  if [[ -n "$vo" ]]; then
    awk '
      /cyclonev_lcell_comb/ { cur=$2; incell=1; ins=""; next }
      incell && /\/\/ .*_combout *=/ { e=$0; sub(/^.*_combout *= */,"",e); eq[cur]=e }
      incell && /\.data[a-g]\(/ {
        if (match($0,/wbe\[[0-9]+\]/)) ins=ins substr($0,RSTART,RLENGTH) " ";
        else if ($0 ~ /\\we\[[0-9]+\]/) ins=ins "we ";
        else if ($0 !~ /\((gnd|vcc)\)/) ins=ins "other "
      }
      incell && /\);/ { lut[cur]=ins; incell=0 }
      /cyclonev_ram_block/ { atom=$2; inram=1 }
      inram && /portabyteenamasks/ { be[atom]=$0 }
      inram && /\);/ { inram=0 }
      END {
        for (a in be) {
          line=be[a]; out=""
          while (match(line,/\\[^ ,}]+_combout/)) {
            nm=substr(line,RSTART,RLENGTH); line=substr(line,RSTART+RLENGTH)
            sub(/_combout$/,"",nm); out=out "[" lut[nm] "]"; eqs=eqs " {" eq[nm] "}"
          }
          b=a; if (match(b,/g_bank\[[0-9]+\]/)) b=substr(b,RSTART,RLENGTH); else b="?"
          printf "%s | %s | byteena_drivers=%s | equations=%s\n", b, a, out, eqs; eqs=""
        }
      }' "$vo" | sort > "$d/byteena_wiring.txt"
  else
    : > "$d/byteena_wiring.txt"
  fi

  line="$name depth=$depth nbank=$nbank style=$style async=$async role=$role | logical=${depth}x64 x${nbank} ($((depth*64*nbank)) bits) | ALM=$alms regs=$regs blockbits=$bits ramblocks=$blocks fmax(probe-only)=$fmax | logical_rams=$n_logical logical_ok(64b,${depth}w,byteena=8,byte=8)=$n_logical_ok fitter_M10K_SDP_rams=$n_fit_m10k m10k_blocks=$m10k_blocks physical_atoms=$n_atoms passthrough_msgs=$passthru uninferred_msgs=$uninferred ignored_assign=$ignored"
  echo "$line" | tee -a "$summary"

  if [[ $role == required ]]; then
    exp_bits=$((depth * 64 * nbank))
    got_bits=$(echo "$bits" | awk '{gsub(/,/,""); print $1}')   # "8,192 / 3,153,920 ( < 1 % )" -> 8192
    fail=""
    unverified=""
    [[ "$got_bits" == "$exp_bits" ]] || fail+=" blockbits=$got_bits!=$exp_bits"
    [[ ${regs:-999999} -lt 64 ]] || fail+=" registers>=64(array-in-FF-or-passthrough?)"
    [[ $passthru -eq 0 ]] || fail+=" pass-through-logic-added"
    [[ $uninferred -eq 0 ]] || fail+=" uninferred-message"
    [[ $ignored -eq 0 ]] || fail+=" ignored-assignment"
    # Byte enables: must be proven, not assumed.
    if [[ $n_logical -eq 0 ]]; then
      unverified+=" no-altsyncram-parameter-table"
    elif [[ $n_logical -ne $nbank || $n_logical_ok -ne $nbank ]]; then
      fail+=" logical-RAM-mismatch(found=$n_logical ok=$n_logical_ok expected=$nbank)"
    fi
    if [[ $n_atoms -eq 0 ]]; then
      unverified+=" no-RAM-atoms-in-netlist"
    else
      [[ $n_fit_m10k -eq $nbank ]] || fail+=" fitter-RAM-not-M10K-SDP-${depth}x64(found=$n_fit_m10k)"
      grep -q "mlabs=0 " "$d/fitter_rams.txt" || fail+=" MLABs-used"
      # every bank must be covered by atoms whose data widths sum to >= 64
      for ((bk=0; bk<nbank; bk++)); do
        wsum=$(awk -v B="g_bank[$bk]" -F' [|] ' '$1==B { if (match($3,/a_width=[0-9]+/)) s+=substr($3,RSTART+8,RLENGTH-8) } END{print s+0}' "$d/physical_ram_atoms.txt")
        [[ $wsum -ge 64 ]] || fail+=" bank$bk-physical-width=$wsum<64"
      done
      grep -qE "a_byteena_width=( |$)|a_byte_size=( |$)" "$d/physical_ram_atoms.txt" && unverified+=" atom-byte-enable-parameters-missing"
      # Per bank: byte-enable lanes x byte size must cover the 8 bytes, and the
      # lanes must be driven by the 8 distinct wbe bits (one wbe bit per lane LUT).
      for ((bk=0; bk<nbank; bk++)); do
        lanes=$(awk -v B="g_bank[$bk]" -F' [|] ' '$1==B { if (match($3,/a_byteena_width=[0-9]+/)) s+=substr($3,RSTART+16,RLENGTH-16) } END{print s+0}' "$d/physical_ram_atoms.txt")
        bad_size=$(awk -v B="g_bank[$bk]" -F' [|] ' '$1==B && $3 !~ /a_byte_size=(8|10)( |$)/ {c++} END{print c+0}' "$d/physical_ram_atoms.txt")
        # Each lane driver must depend on exactly one wbe bit and the bank's we (we & wbe[i]).
        wiring=$(awk -v B="g_bank[$bk]" -F' [|] ' '$1==B {print $3}' "$d/byteena_wiring.txt" | grep -oE "wbe\[[0-9]+\]" | sort -u | wc -l | tr -d ' ')
        # split "byteena_drivers=[a ][b ]..." into one driver per line (driver text contains "]")
        impure=$(awk -v B="g_bank[$bk]" -F' [|] ' '$1==B {d=$3; sub(/^byteena_drivers=\[/,"",d); sub(/\]$/,"",d); n=split(d,x,/ \]\[/); for(i=1;i<=n;i++){t=x[i]; sub(/ $/,"",t); print t}}' "$d/byteena_wiring.txt" | grep -cvE "^(wbe\[[0-9]+\] we|we wbe\[[0-9]+\])$" || true)
        [[ $lanes -eq 8 ]] || fail+=" bank$bk-byteena-lanes=$lanes!=8"
        [[ $bad_size -eq 0 ]] || fail+=" bank$bk-byte-size-not-8or10"
        if [[ ! -s "$d/byteena_wiring.txt" ]]; then
          unverified+=" bank$bk-byteena-wiring-not-extracted"
        else
          [[ $wiring -eq 8 && $impure -eq 0 ]] || fail+=" bank$bk-byteena-wiring(distinct_wbe=$wiring other_inputs=$impure)"
        fi
      done
    fi
    if [[ -n "$fail" ]]; then
      echo "FAIL $name:$fail${unverified:+ (also unverified:$unverified)}" | tee -a "$summary"; overall=1
    elif [[ -n "$unverified" ]]; then
      echo "UNVERIFIED $name:$unverified (not a PASS)" | tee -a "$summary"; overall=1
    else
      echo "PASS $name (see $d/logical_rams.txt, $d/physical_ram_atoms.txt)" | tee -a "$summary"
    fi
  fi
done <<< "$configs"
exit $overall
