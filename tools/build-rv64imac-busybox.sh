#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${BUSYBOX_SRC:=$repo_root/build/toolchain-src/busybox}"
: "${TOOLCHAIN_DIR:=$repo_root/build/riscv-musl-lp64}"
: "${OUT_DIR:=$repo_root/build/busybox-out/rv64imac-lp64}"
: "${JOBS:=8}"
: "${DOCKER_IMAGE:=ubuntu:24.04}"

# Dockerコンテナ内から参照するパス
busybox_src_container="/repo/${BUSYBOX_SRC#"$repo_root"/}"
toolchain_dir_container="/repo/${TOOLCHAIN_DIR#"$repo_root"/}"
out_dir_container="/repo/${OUT_DIR#"$repo_root"/}"
toolchain_prefix_container="$toolchain_dir_container/bin/riscv64-unknown-linux-musl-"

if [[ "$BUSYBOX_SRC" != "$repo_root"/* ]]; then
  echo "BUSYBOX_SRC must be inside repository: $BUSYBOX_SRC" >&2
  exit 1
fi

if [[ "$TOOLCHAIN_DIR" != "$repo_root"/* ]]; then
  echo "TOOLCHAIN_DIR must be inside repository: $TOOLCHAIN_DIR" >&2
  exit 1
fi

if [[ "$OUT_DIR" != "$repo_root"/* ]]; then
  echo "OUT_DIR must be inside repository: $OUT_DIR" >&2
  exit 1
fi

if [[ ! -d "$BUSYBOX_SRC" ]]; then
  echo "missing BusyBox source: $BUSYBOX_SRC" >&2
  echo "expected BusyBox 1.36.1 source at this location" >&2
  exit 1
fi

if [[ ! -f "$BUSYBOX_SRC/Makefile" ]]; then
  echo "invalid BusyBox source tree: $BUSYBOX_SRC" >&2
  exit 1
fi

cc="$TOOLCHAIN_DIR/bin/riscv64-unknown-linux-musl-gcc"

if [[ ! -f "$cc" ]]; then
  echo "missing compiler: $cc" >&2
  echo "run tools/build-rv64imac-musl-toolchain.sh first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

docker run --rm \
  -v "$repo_root:/repo" \
  -w /repo \
  "$DOCKER_IMAGE" \
  bash -lc "
    set -euo pipefail

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y -qq \
      make \
      gcc \
      perl \
      file \
      bzip2 \
      ca-certificates \
      >/tmp/apt.log

    BUSYBOX_SRC='$busybox_src_container'
    OUT_DIR='$out_dir_container'
    TOOLCHAIN_PREFIX='$toolchain_prefix_container'
    JOBS='$JOBS'

    cc=\"\${TOOLCHAIN_PREFIX}gcc\"
    readelf=\"\${TOOLCHAIN_PREFIX}readelf\"
    objdump=\"\${TOOLCHAIN_PREFIX}objdump\"

    if [[ ! -x \"\$cc\" ]]; then
      echo \"compiler is not executable inside container: \$cc\" >&2
      file \"\$cc\" || true
      exit 1
    fi

    rm -rf \"\$OUT_DIR\"
    mkdir -p \"\$OUT_DIR\"

    make -C \"\$BUSYBOX_SRC\" O=\"\$OUT_DIR\" \
      ARCH=riscv \
      CROSS_COMPILE=\"\$TOOLCHAIN_PREFIX\" \
      defconfig

    set_config() {
      local key=\"\$1\"
      local value=\"\$2\"

      if grep -qE \"^\${key}=|^# \${key} is not set\" \"\$OUT_DIR/.config\"; then
        perl -0pi -e \
          \"s/^\${key}=.*\$/\${key}=\${value}/m; s/^# \${key} is not set\$/\${key}=\${value}/m\" \
          \"\$OUT_DIR/.config\"
      else
        printf '%s=%s\n' \"\$key\" \"\$value\" >> \"\$OUT_DIR/.config\"
      fi
    }

    unset_config() {
      local key=\"\$1\"

      if grep -qE \"^\${key}=|^# \${key} is not set\" \"\$OUT_DIR/.config\"; then
        perl -0pi -e \
          \"s/^\${key}=.*\$/# \${key} is not set/m\" \
          \"\$OUT_DIR/.config\"
      else
        printf '# %s is not set\n' \"\$key\" >> \"\$OUT_DIR/.config\"
      fi
    }

    set_config CONFIG_STATIC y
    unset_config CONFIG_FEATURE_PREFER_APPLETS
    unset_config CONFIG_TC
    unset_config CONFIG_FEATURE_TC_INGRESS

    set +o pipefail
    yes '' | make -C \"\$BUSYBOX_SRC\" O=\"\$OUT_DIR\" \
      ARCH=riscv \
      CROSS_COMPILE=\"\$TOOLCHAIN_PREFIX\" \
      oldconfig
    oldconfig_status=\${PIPESTATUS[1]}
    set -o pipefail

    if [[ \"\$oldconfig_status\" -ne 0 ]]; then
      echo \"BusyBox oldconfig failed: \$oldconfig_status\" >&2
      exit \"\$oldconfig_status\"
    fi

    make -C \"\$BUSYBOX_SRC\" O=\"\$OUT_DIR\" \
      ARCH=riscv \
      CROSS_COMPILE=\"\$TOOLCHAIN_PREFIX\" \
      KCFLAGS='-march=rv64imac -mabi=lp64' \
      -j\"\$JOBS\" \
      busybox

    echo '===== BusyBox file information ====='
    file \"\$OUT_DIR/busybox\"

    echo '===== ELF header ====='
    \"\$readelf\" -h \"\$OUT_DIR/busybox\" \
      | grep -E 'Class|Type|Machine|Flags'

    echo '===== RISC-V attributes ====='
    \"\$readelf\" -A \"\$OUT_DIR/busybox\" || true

    echo '===== F/D instruction check ====='
    if \"\$objdump\" -d \"\$OUT_DIR/busybox\" \
      | grep -E '\\b(fld|fsd|flw|fsw|fadd|fsub|fmul|fdiv|c\\.fld|c\\.fsd)\\b'
    then
      echo 'unexpected F/D instruction found' >&2
      exit 1
    fi

    echo 'BusyBox build completed successfully.'
  "

busybox_bin="$OUT_DIR/busybox"

if [[ ! -f "$busybox_bin" ]]; then
  echo "BusyBox output was not generated: $busybox_bin" >&2
  exit 1
fi

echo "$busybox_bin"
