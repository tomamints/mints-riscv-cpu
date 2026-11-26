#!/usr/bin/env bash
# Generate RV64 ACT4 tests with Sail and run the self-checking ELFs in Verilator.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
revision=${ACT4_REVISION:-98a1ec7b0ae0373e25b015cb0f4bf8b0dd5f9924}
simulator=${VERILATOR_IMAGE:-mints-linux-verilator:5.046}
jobs=${JOBS:-4}

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [path-to-act4-checkout]" >&2
    exit 2
fi
mkdir -p build/act4
out=$(mktemp -d "$repo/build/act4/run.XXXXXX")
relative=${out#"$repo"/}
echo "ACT4 output $out"
if [[ $# -eq 1 ]]; then
    source=$(cd "$1" && pwd)
    # Include local source edits while keeping generation in an isolated copy.
    mkdir "$out/source"
    tar -C "$source" --exclude=.git --exclude=.venv --exclude=.bundle \
        --exclude=work --exclude=__pycache__ -cf - . | tar -C "$out/source" -xf -
    git -C "$source" rev-parse HEAD > "$out/source-revision"
    git -C "$source" status --porcelain > "$out/source-status"
else
    git init -q "$out/source"
    git -C "$out/source" fetch -q --depth=1 https://github.com/riscv/riscv-arch-test.git "$revision"
    git -C "$out/source" checkout -q --detach FETCH_HEAD
    git -C "$out/source" rev-parse HEAD > "$out/source-revision"
fi

python3 tools/act4/prepare.py "$out/source" "$out/config"
if [[ -n ${ACT4_IMAGE:-} ]]; then
    generator=$ACT4_IMAGE
else
    generator=mints-act4:sail-0.16
    docker build -t "$generator" tools/act4
fi
docker image inspect "$generator" --format '{{.Id}}' > "$out/generator-image"
generation_status=0
docker run --rm --init -e MISE_TRUSTED_CONFIG_PATHS=/act4 \
    -v "$out/source:/act4" -v "$out/config:/cfg:ro" -v "$out:/work" \
    "$generator" bash -ec '
        make tests WORKDIR=/work/generated JOBS="$1"
        mise exec -- uv run act /cfg/test_config.yaml --workdir /work/generated \
            --jobs "$1" --extensions "$2" --keep-going
    ' act4 "$jobs" "${ACT4_SUITES:-all}" 2>&1 | tee "$out/generate.log" || generation_status=$?

simulation_status=0
docker run --rm --init -e ACT4_OUT="$relative" -e ACT4_JOBS="$jobs" \
    -v "$repo:/repo" -w /repo "$simulator" bash tools/act4/run-elfs.sh || simulation_status=$?
echo "ACT4 generation exit=$generation_status, MiNTs simulation exit=$simulation_status"
(( generation_status == 0 && simulation_status == 0 ))
