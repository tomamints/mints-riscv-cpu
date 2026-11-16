#!/usr/bin/env bash
# Native Apple Silicon USB-Blaster support, installed locally without Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)-$(uname -m)" == Darwin-arm64 ]] || {
  echo 'This setup script targets Apple Silicon macOS.' >&2; exit 1;
}
mkdir -p local/micromamba build/logs
if [[ ! -x local/micromamba/bin/micromamba ]]; then
  curl -fL --retry 3 https://micro.mamba.pm/api/micromamba/osx-arm64/2.10.0 \
    -o local/micromamba/micromamba.tar.bz2
  tar xjf local/micromamba/micromamba.tar.bz2 -C local/micromamba bin/micromamba
fi
action=create
[[ ! -d local/fpga-tools/conda-meta ]] || action=install
local/micromamba/bin/micromamba "$action" --root-prefix "$PWD/local/mamba-root" \
  --prefix "$PWD/local/fpga-tools" -c conda-forge -y \
  cmake=4.4.5 pkg-config=0.29.2 libftdi=1.5 libusb=1.0.30 zlib=1.3.2
if [[ ! -d local/openfpgaloader-src/.git ]]; then
  git clone --depth 1 --branch v1.2.0 \
    https://github.com/trabucayre/openFPGALoader.git local/openfpgaloader-src
fi
[[ "$(git -C local/openfpgaloader-src rev-parse HEAD)" == \
   befbab4f646207dbaf1daf8b144dd980ad283dd5 ]] || {
  echo 'Unexpected openFPGALoader source revision.' >&2; exit 1;
}
export PATH="$PWD/local/fpga-tools/bin:$PATH"
export PKG_CONFIG_PATH="$PWD/local/fpga-tools/lib/pkgconfig"
cmake -S local/openfpgaloader-src -B build/openfpgaloader-native \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PWD/local/fpga-tools" \
  -DCMAKE_INSTALL_PREFIX="$PWD/local/fpga-tools" \
  -DENABLE_CABLE_ALL=OFF -DENABLE_USB_BLASTERI=ON -DENABLE_USB_BLASTERII=ON \
  -DENABLE_VENDORS_ALL=OFF -DENABLE_ALTERA_SUPPORT=ON
cmake --build build/openfpgaloader-native -j4
cmake --install build/openfpgaloader-native
# Upstream installs the binary as a file; add the local dylib search path.
if ! otool -l local/fpga-tools/bin/openFPGALoader | grep -F '@executable_path/../lib' >/dev/null; then
  install_name_tool -add_rpath '@executable_path/../lib' local/fpga-tools/bin/openFPGALoader
fi
codesign --force --sign - local/fpga-tools/bin/openFPGALoader
local/micromamba/bin/micromamba list --root-prefix "$PWD/local/mamba-root" \
  --prefix "$PWD/local/fpga-tools" --explicit > build/logs/de0cv-programmer-packages.txt
echo 'Ready: local/fpga-tools/bin/openFPGALoader --detect -c usb-blaster'
