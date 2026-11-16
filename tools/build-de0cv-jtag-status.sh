#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Reuse the pinned openFPGALoader transport objects from the programmer setup.
[[ -f build/openfpgaloader-native/CMakeFiles/openFPGALoader.dir/link.txt ]] || bash tools/setup-de0cv-programmer.sh
python3 - <<'PY'
import pathlib, shlex, subprocess
root=pathlib.Path.cwd()
build=root/'build/openfpgaloader-native'
obj=root/'build/de0cv-jtag-status.o'
out=root/'local/fpga-tools/bin/de0cv-jtag-status'
subprocess.run(['/usr/bin/c++','-std=c++17','-O2','-arch','arm64',
    '-I'+str(root/'local/openfpgaloader-src/src'),'-c',
    str(root/'tools/de0cv-jtag-status.cpp'),'-o',str(obj)],check=True)
args=shlex.split((build/'CMakeFiles/openFPGALoader.dir/link.txt').read_text())
args=[str(obj) if x.endswith('/src/main.cpp.o') else x for x in args]
args[args.index('-o')+1]=str(out)
subprocess.run(args,cwd=build,check=True)
subprocess.run(['codesign','--force','--sign','-',str(out)],check=True)
PY
