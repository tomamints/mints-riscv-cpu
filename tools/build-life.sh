#!/usr/bin/env bash
# Run inside the Linux build container after the musl toolchain stage.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LIFE_CC:=$PWD/build/riscv-musl-lp64/bin/riscv64-linux-musl-gcc}"
mkdir -p build/apps
"$LIFE_CC" -std=c11 -O2 -Wall -Wextra -Werror -static -march=rv64imac -mabi=lp64 \
  examples/life/life.c -o build/apps/life

"$LIFE_CC" -std=c11 -O2 -Wall -Wextra -Werror -static -march=rv64imac -mabi=lp64 \
  examples/boardctl/boardctl.c -o build/apps/boardctl
