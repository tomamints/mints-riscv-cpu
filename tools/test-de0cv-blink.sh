#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
docker run --rm --init -v "$PWD:/repo" "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" \
  bash -c 'set -euo pipefail
    mkdir -p build/test/blink
    verilator --binary --timing --assert -Wall --top-module tb_de0_cv_blink \
      --Mdir build/test/blink/obj -o blink-test \
      fpga/de0-cv/blink/rtl/de0_cv_blink.sv tb/unit/blink/tb_de0_cv_blink.sv \
      > build/test/blink/build.log 2>&1
    build/test/blink/obj/blink-test | tee build/test/blink/test.log'
