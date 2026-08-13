# WhisperでRV64 bare-metal ELFを実行する手順

Last updated: 2026-08-13

現在のMiNTs-CPU lockstep実行手順は
`tools/whisper_lockstep/README.md` と `Docs/LINUX_SETUP.md` を優先してください。
この文書はWhisper単体導入や過去の試行ログを含む補助メモです。

## 1. Whisperをcloneする

```bash
git clone https://github.com/tenstorrent/whisper.git
cd whisper
```

---

## 2. Docker環境を起動する

Colimaの`riscv-build`プロファイルを使う場合:

```bash
colima start --profile riscv-build
```

確認:

```bash
docker info
docker run --rm hello-world
```

---

## 3. macOSで生成されたビルド成果物を削除する

macOSとLinuxのオブジェクトを混在させないため、既存の生成物を削除する。

```bash
cd ~/r/whisper

rm -rf build-Linux

rm -f \
  virtual_memory/*.o \
  virtual_memory/*.d \
  virtual_memory/*.a
```

必要に応じてMach-O形式の生成物を探す。

```bash
find . -type f \( -name '*.o' -o -name '*.a' \) -print0 \
  | xargs -0 file \
  | grep 'Mach-O'
```

表示されたものがビルド生成物であれば削除する。

---

## 4. WhisperをUbuntu Docker内でビルドする

```bash
cd ~/r/whisper

docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper \
  ubuntu:24.04 \
  bash -lc '
    set -euo pipefail

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      build-essential \
      g++ \
      make \
      git \
      libboost-all-dev \
      liblz4-dev \
      linux-libc-dev \
      python3-dev \
      pybind11-dev \
      pkg-config \
      file \
      binutils

    make -f GNUmakefile clean || true

    rm -rf build-Linux

    rm -f \
      virtual_memory/*.o \
      virtual_memory/*.d \
      virtual_memory/*.a

    make -f GNUmakefile -j4
  '
```

`BOOST_DIR=/usr`は指定しない。

---

## 5. ビルド結果を確認する

```bash
docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper \
  ubuntu:24.04 \
  bash -lc '
    file build-Linux/whisper
    file virtual_memory/VirtMem.o
  '
```

期待する形式:

```text
ELF 64-bit
```

Whisperのhelpを確認する。

```bash
docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper \
  ubuntu:24.04 \
  ./build-Linux/whisper --help
```

---

## 6. bare-metalテスト用ディレクトリを作る

```bash
mkdir -p ~/r/whisper/mints-smoke
cd ~/r/whisper/mints-smoke
```

---

## 7. `smoke.S`を作る

```asm
.section .text
.globl _start

_start:
    li      x1, 10
    li      x2, 20
    add     x3, x1, x2

    la      x4, result
    sd      x3, 0(x4)
    ld      x5, 0(x4)

    bne     x3, x5, fail

pass:
    la      x6, tohost
    li      x7, 1
    sd      x7, 0(x6)

1:
    j       1b

fail:
    la      x6, tohost
    li      x7, 3
    sd      x7, 0(x6)

2:
    j       2b

.section .data
.align 3

result:
    .dword 0

.globl tohost
.align 3

tohost:
    .dword 0
```

---

## 8. `smoke.ld`を作る

```ld
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : {
        *(.text*)
    }

    . = ALIGN(8);

    .rodata : {
        *(.rodata*)
    }

    .data : {
        *(.data*)
    }

    .bss : {
        *(.bss*)
        *(COMMON)
    }
}
```

---

## 9. RV64 ELFをビルドする

```bash
cd ~/r/whisper

docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper/mints-smoke \
  ubuntu:24.04 \
  bash -lc '
    set -euo pipefail

    apt-get update -qq

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      gcc-riscv64-unknown-elf \
      binutils-riscv64-unknown-elf

    riscv64-unknown-elf-gcc \
      -march=rv64ima_zicsr \
      -mabi=lp64 \
      -nostdlib \
      -nostartfiles \
      -static \
      -T smoke.ld \
      -o smoke.elf \
      smoke.S

    riscv64-unknown-elf-readelf -h smoke.elf
    riscv64-unknown-elf-objdump -d smoke.elf
  '
```

entry pointが次になっていることを確認する。

```text
0x80000000
```

---

## 10. WhisperでELFを実行する

```bash
cd ~/r/whisper

docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper \
  ubuntu:24.04 \
  ./build-Linux/whisper \
    --raw \
    --isa rv64ima_zicsr \
    --startpc 0x80000000 \
    --log \
    --traceload \
    /whisper/mints-smoke/smoke.elf
```

ELFは`--target`ではなく、最後の位置引数として渡す。

`--startpc`にはリンカスクリプトで指定した開始アドレスを設定する。

---

## 11. CSVログを保存する

```bash
docker run --rm \
  -v "$PWD:/whisper" \
  -w /whisper \
  ubuntu:24.04 \
  ./build-Linux/whisper \
    --raw \
    --isa rv64ima_zicsr \
    --startpc 0x80000000 \
    --logfile /whisper/mints-smoke/whisper.csv \
    --csvlog \
    --traceload \
    /whisper/mints-smoke/smoke.elf
```

確認:

```bash
head -30 ~/r/whisper/mints-smoke/whisper.csv
```

---

## 12. 再ビルド時の注意

ホスト側のmacOSでWhisperをビルドしない。

Docker内で再ビルドする前に、少なくとも以下を削除する。

```bash
rm -rf build-Linux

rm -f \
  virtual_memory/*.o \
  virtual_memory/*.d \
  virtual_memory/*.a
```

`virtual_memory/VirtMem.o`がLinux用か確認する。

```bash
file virtual_memory/VirtMem.o
```

期待値:

```text
ELF 64-bit LSB relocatable
```

次のように表示された場合は削除して再ビルドする。

```text
Mach-O 64-bit object
```



===========================


cd "$HOME/risc-v-cpu"

docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  ubuntu:24.04 \
  bash -lc '
    set -eux

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential \
      git \
      autoconf \
      flex \
      bison \
      help2man \
      perl \
      python3 \
      libfl-dev \
      linux-libc-dev \
      libboost-dev \
      zlib1g-dev

    git clone \
      --depth 1 \
      --branch v5.046 \
      https://github.com/verilator/verilator.git \
      /tmp/verilator

    cd /tmp/verilator
    autoconf
    ./configure
    make -j"$(nproc)"
    make install

    cd /work

    rm -rf obj_dir_lockstep
    make build-lockstep
  '

  ビビルド


cd "$HOME/risc-v-cpu"

rm -rf obj_dir_lockstep

docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  ubuntu:24.04 \
  bash -lc '
    set -eux

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential \
      make \
      g++ \
      verilator \
      zlib1g-dev

    make build-lockstep
  '

成功後↓↓↓

docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  ubuntu:24.04 \
  bash -lc '
    set -eux

    WHISPER_OPENSBI_ELF=/work/build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
    WHISPER_DTB=/work/build/platform/riscv_cpu.dtb \
    DBG_ADDR=0x40000000 \
    ./obj_dir_lockstep/sim \
      build/platform/bootrom_linux.hex \
      build/platform/opensbi_ram.hex \
      1000000
  '


Whisper変更後
docker run --rm \
  -v "$HOME/risc-v-cpu:/work" \
  -w /work/whisper \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    set -eux
    make -f GNUmakefile BUILD_DIR=build-Linux build-Linux/librvcore.a
  '


ビルド
cd "$HOME/risc-v-cpu"

rm -rf obj_dir_lockstep

docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    set -eux
    make build-lockstep
  '
