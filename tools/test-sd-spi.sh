#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm --init -v "$PWD:/repo" -w /repo "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
set -euo pipefail
out=build/test/sd-spi
mkdir -p "$out"
for kind in spi board; do
defines=()
[[ $kind != board ]] || defines+=(-DSD_SPI_BOARD_WRAPPER=1)
verilator --binary --timing --assert -j 4 -Wno-fatal -Wno-TIMESCALEMOD --top-module tb_sd_spi_mmio \
 "${defines[@]}" --Mdir "$out/obj-$kind" -o sim src/eei.sv src/membus_if.sv fpga/de0-cv/sd/rtl/sd_spi_mmio.sv rtl/peripheral/board_gpio_mmio.sv rtl/peripheral/board_io_mmio.sv tb/unit/tb_sd_spi_mmio.sv >"$out/build-$kind.log" 2>&1
"$out/obj-$kind/sim" | tee "$out/run-$kind.log"
grep -q SD_SPI_PASS "$out/run-$kind.log"
done
'
