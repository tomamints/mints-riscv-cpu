#!/usr/bin/env bash
# Fetch pinned upstream ISA tests and build RV64 integer/privileged p suites.
# Third-party sources and generated binaries remain outside Git tracking.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Docker.app/Contents/Resources/bin ]]; then
  export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
fi
revision=3df703cd52d5f0d8224e3c50bf03c6cb70efff98
environment_revision=6de71edb142be36319e380ce782c3d1830c65d68
source_dir=local/riscv-tests
if [[ ! -d "$source_dir/.git" ]]; then
  git clone --filter=blob:none --no-checkout \
    https://github.com/riscv-software-src/riscv-tests.git "$source_dir"
  git -C "$source_dir" checkout --detach "$revision"
  git -C "$source_dir" submodule update --init --recursive --depth 1
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]]
[[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]
git -C "$source_dir" submodule update --init --recursive --depth 1
[[ "$(git -C "$source_dir/env" rev-parse HEAD)" == "$environment_revision" ]]
out=build/riscv-tests
if [[ -e "$out" ]]; then
  mkdir -p build/test/archive
  mv "$out" "build/test/archive/riscv-tests-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out/env"
git -C "$source_dir" archive HEAD isa LICENSE | tar -x -C "$out"
git -C "$source_dir/env" archive HEAD | tar -x -C "$out/env"
cat >"$out/selected.mk" <<'MAKE'
.PHONY: selected
selected: $(rv64ui_p_tests) $(rv64um_p_tests) $(rv64ua_p_tests) $(rv64uc_p_tests) $(rv64mi_p_tests) $(rv64si_p_tests)
MAKE
printf 'riscv-tests=%s\nriscv-test-env=%s\n' "$revision" "$environment_revision" >"$out/versions.txt"
docker run --rm --init -v "$PWD:/repo" -w /repo \
  "${DOCKER_IMAGE:-mints-linux-verilator:5.046}" bash -c '
    set -euo pipefail
    out=build/riscv-tests
    riscv64-unknown-elf-gcc --version >> "$out/versions.txt"
    make -C "$out/isa" -f Makefile -f ../selected.mk -j2 selected > "$out/build.log" 2>&1
    python3 - <<'"'"'PY'"'"'
from pathlib import Path
import subprocess
paths=[]
for elf in sorted(Path("build/riscv-tests/isa").glob("rv64*-p-*")):
    if elf.read_bytes()[:4] != b"\x7fELF":
        continue
    binary=Path(str(elf)+".bin")
    subprocess.run(["riscv64-unknown-elf-objcopy","-O","binary",str(elf),str(binary)],check=True)
    with Path(str(binary)+".hex").open("w") as target:
        subprocess.run(["python3","tools/bin2hex.py","8",str(binary)],stdout=target,check=True)
    paths.append(str(elf))
if not paths:
    raise SystemExit("No ISA ELF tests produced")
Path("build/riscv-tests/elf-list.txt").write_text("\n".join(paths)+"\n")
print(f"Built {len(paths)} pinned RV64 p-suite tests")
PY
  '
