#!/usr/bin/env bash
# Verify FIFO width-based ports against the immutable typed implementation and
# an independent queue, including packed payloads, flushes and backpressure.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
revision=832fc9e1d7014a0479bb59e7783640a9b1314dc4
baseline=build/baseline/fifo-832fc9e/fifo.sv
if [[ ! -f "$baseline" ]]; then
  mkdir -p "$(dirname "$baseline")"
  git cat-file -e "$revision:src/fifo.sv" 2>/dev/null || git fetch --no-tags origin "$revision"
  git show "$revision:src/fifo.sv" > "$baseline"
fi
python3 - "$baseline" <<'PY'
import hashlib, pathlib, sys
path=pathlib.Path(sys.argv[1])
expected='2abad95b8f806d52006cf0e52bb82aa6452f4404d4642771fb612da8db23342a'
if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
    raise SystemExit('FIFO baseline hash mismatch')
PY
docker run --rm --init -v "$PWD:/repo" -w /repo \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
    set -euo pipefail
    out=build/test/fifo-contract
    if [[ -e "$out" ]]; then
      mkdir -p build/test/archive
      mv "$out" "build/test/archive/fifo-contract-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    mkdir -p "$out"
    baseline=build/baseline/fifo-832fc9e/fifo.sv
    sed "s/^module fifo #(/module fifo_baseline #(/" "$baseline" > "$out/fifo_baseline.sv"
    sha256sum "$baseline" src/fifo.sv src/core.sv src/inst_fetcher.sv \
      tb/unit/fifo/tb_fifo_contract.sv > "$out/sources.sha256"
    verilator --lint-only -Wall --top-module fifo src/fifo.sv > "$out/lint.log" 2>&1
    verilator --binary --timing --assert --timescale 1ns/1ps \
      --top-module tb_fifo_contract --Mdir "$out/obj" -o sim \
      "$out/fifo_baseline.sv" src/fifo.sv tb/unit/fifo/tb_fifo_contract.sv \
      > "$out/build.log" 2>&1
    "$out/obj/sim" > "$out/run.log" 2>&1
    grep -q "^FIFO_ALL_CONTRACT_PASS" "$out/run.log"
    cat "$out/run.log"
  '
