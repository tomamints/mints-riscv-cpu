#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
out=build/test/pmp-prefix
mkdir -p "$out"
git show 9b7257c:src/pmp_checker.sv > "$out/reference-original.sv"
test "$(shasum -a 256 "$out/reference-original.sv" | cut -d ' ' -f1)" = b3a1312262f8f440ec096464452838b412126a025ac2d45417105c6c1b98b9e8
sed 's/module pmp_checker (/module pmp_checker_reference (/; s/endmodule : pmp_checker/endmodule : pmp_checker_reference/' \
  "$out/reference-original.sv" > "$out/pmp_checker_reference.sv"
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/pmp-prefix
verilator --binary --timing --assert -Wno-fatal --top-module tb_pmp_prefix \
  --Mdir "$out/obj" -o sim src/eei.sv src/pmp_checker.sv "$out/pmp_checker_reference.sv" \
  tb/unit/sdram/tb_pmp_prefix.sv > "$out/build.log" 2>&1
"$out/obj/sim" > "$out/run.log" 2>&1
grep "^PMP_PREFIX_PASS" "$out/run.log"
'
