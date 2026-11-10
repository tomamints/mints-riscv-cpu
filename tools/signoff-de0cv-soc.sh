#!/usr/bin/env bash
# Signoff of an assembled DE0-CV SoC build (tools/build-de0cv-soc.sh STAGE=asm):
# refuses critical warnings / ignored assignments, runs the SoC STA checks on
# every corner, checks fitted pins/IO, converts SOF -> RBF (for openFPGALoader
# SRAM programming) and records checksums. Never programs the board.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
out=build/fpga/de0cv-soc
q=$out/quartus
r=$q/output_files
[[ -s $r/de0cv_soc.sof ]] || { echo "missing $r/de0cv_soc.sof (build with STAGE=asm)" >&2; exit 1; }
if grep -nE 'Critical Warning|Ignored assignment' "$r"/*.rpt; then
  echo 'SIGNOFF FAIL: critical warnings or ignored assignments' >&2; exit 1
fi
cp fpga/de0-cv/soc/check_constraints.tcl "$q/"
qb=/opt/intelFPGA_lite/20.1/quartus/bin
docker run --rm --init --platform linux/amd64 \
  -v "${QUARTUS_VOLUME:-mints-quartus-20.1}:/opt/intelFPGA_lite" -v "$PWD/$out:/work" -w /work/quartus \
  -e LD_PRELOAD=/lib/x86_64-linux-gnu/libudev.so.1 "${QUARTUS_IMAGE:-mints-quartus:20.1}" bash -c "
    $qb/quartus_sta -t check_constraints.tcl > check_constraints.log 2>&1
    $qb/quartus_cpf -c output_files/de0cv_soc.sof output_files/de0cv_soc.rbf > cpf.log 2>&1" || true
grep -q 'check_constraints: all checks passed' "$q/check_constraints.log" || {
  grep -E 'CHECK FAIL|Error' "$q/check_constraints.log" | head -20; echo 'SIGNOFF FAIL: constraints' >&2; exit 1; }
grep -E 'CHECK .* (setup|hold|recovery|removal) slack' "$q/check_constraints.log" | sed 's/^Info: //' |
  awk '{print $(NF-2), $(NF-1), $NF}' | sort -t= -k2 -g | head -3 | sed 's/^/worst: /'
bash tools/check-de0cv-soc-pins.sh "$r/de0cv_soc.pin"
[[ -s $r/de0cv_soc.rbf ]] || { cat "$q/cpf.log"; echo 'SIGNOFF FAIL: no RBF' >&2; exit 1; }
(cd "$r" && shasum -a 256 de0cv_soc.sof de0cv_soc.rbf) > "$r/sha256.txt"
cat "$out/profile.txt" > "$out/signoff.txt"
{ cat "$out/sources.sha256"; cat "$r/sha256.txt"; echo "SIGNOFF PASS $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$out/signoff.txt"
echo "SIGNOFF PASS: $r/de0cv_soc.rbf"
