# Rebuild from Clean

MiNTs-CPUで `build/` を削除したあとに、OpenSBI、RISC-V musl toolchain、BusyBox、Linux Imageを再生成する手順です。

## 注意

現在のプロジェクトルートの `make clean` は、Verilator生成物だけでなく `build/` ディレクトリ全体を削除します。

そのため、以下も削除されます。

* OpenSBI source / build output
* musl source
* RISC-V musl toolchain
* BusyBox source / binary
* Linux build output
* DTB
* 各種テスト生成物

Verilatorの生成物だけを削除したい場合は、次を使います。

```sh
rm -rf obj_dir obj_dir_input obj_dir_trace
```

## 使用バージョン

* OpenSBI: `v1.3.1`
* Linux: `v6.12.97`
* BusyBox: `1.36.1`
* Bare-metal GCC: `riscv64-unknown-elf-gcc 15.1.0`
* Target ISA: `rv64imac`
* Target ABI: `lp64`
* Docker image: `ubuntu:24.04`
* Linux source Docker volume: `linux-6.12-src`

## 依存関係

```text
OpenSBI
└── riscv64-unknown-elf toolchain

Linux Image
└── BusyBox
    └── rv64imac/lp64 musl toolchain
        └── musl / riscv-gnu-toolchain source

Linux source
└── Docker volume: linux-6.12-src
```

---

## 1. OpenSBI sourceの復元

```sh
mkdir -p build/external

git clone https://github.com/riscv-software-src/opensbi.git \
  build/external/opensbi

git -C build/external/opensbi checkout v1.3.1
```

OpenSBI v1.3.1は、GCC 15のC23モードでは次のエラーになる場合があります。

```text
error: 'bool' cannot be defined via 'typedef'
```

そのため、`tools/build-opensbi.sh`ではGCCへ `-std=gnu11` を付けてビルドします。

```sh
chmod +x tools/build-opensbi.sh
tools/build-opensbi.sh
```

生成物を確認します。

```sh
ls -lh \
  build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
```

期待する生成物:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
```

---

## 2. musl sourceの復元

```sh
mkdir -p build/toolchain-src

git clone https://git.musl-libc.org/git/musl \
  build/toolchain-src/musl
```

確認:

```sh
test -f build/toolchain-src/musl/configure \
  && echo "musl source OK"
```

---

## 3. rv64imac/lp64 musl toolchainのビルド

ColimaのDocker socketを指定して実行します。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
tools/build-rv64imac-musl-toolchain.sh
```

生成物:

```text
build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-gcc
```

確認:

```sh
ls -lh \
  build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-gcc

file \
  build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-gcc
```

このコンパイラはLinux上で実行するELFファイルです。

macOS上で直接実行すると、次のエラーになります。

```text
cannot execute binary file
Exec format error
```

そのため、BusyBoxのビルドもDockerコンテナ内で行います。

---

## 4. BusyBox sourceの復元

```sh
git clone https://git.busybox.net/busybox \
  build/toolchain-src/busybox
```

以前使用していたBusyBox 1.36.1へ固定します。

```sh
git -C build/toolchain-src/busybox checkout 1_36_1
```

確認:

```sh
git -C build/toolchain-src/busybox describe --tags --always
```

期待値:

```text
1_36_1
```

---

## 5. BusyBoxのビルド

BusyBoxのビルドはDocker内で行います。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
tools/build-rv64imac-busybox.sh
```

生成物:

```text
build/busybox-out/rv64imac-lp64/busybox
```

確認:

```sh
ls -lh build/busybox-out/rv64imac-lp64/busybox

file build/busybox-out/rv64imac-lp64/busybox
```

期待する属性:

```text
ELF 64-bit
UCB RISC-V
RVC
soft-float ABI
statically linked
```

RISC-V ELF headerの確認:

```sh
build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-readelf \
  -h build/busybox-out/rv64imac-lp64/busybox
```

ただし、上記の `readelf` もLinux用の場合はmacOS上で直接実行できません。通常は `tools/build-rv64imac-busybox.sh` 内のDocker環境で確認します。

正常時の例:

```text
Class:   ELF64
Type:    EXEC
Machine: RISC-V
Flags:   RVC, soft-float ABI
```

F/D命令が含まれていないことも、ビルドスクリプト内の `objdump` で確認します。

---

## 6. Linux source Docker volumeの確認

Linux sourceは、macOSのcase-insensitive filesystem問題を避けるため、Docker volumeに置きます。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker volume ls | grep linux-6.12-src
```

期待する表示:

```text
local     linux-6.12-src
```

volumeが存在する場合、Linux Image生成時は `LINUX_SRC` ではなく、次を使います。

```sh
LINUX_SRC_VOLUME=linux-6.12-src
```

次の指定は、ローカルのLinux sourceディレクトリが存在しない場合は使えません。

```sh
LINUX_SRC=build/external/linux
```

---

## 7. BusyBox initramfs入りLinux Imageのビルド

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
INIT_SCRIPT_MODE=cmdloop-ttyS0 \
IMAGE_NAME=Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
LINUX_SRC_VOLUME=linux-6.12-src \
LINUX_OUT=build/external/linux-out \
KBUILD_OUT=build/linux-build-busybox-cmdloop-ttyS0-irqcause-min \
JOBS=4 \
tools/build-linux-busybox-initramfs-image.sh
```

生成物:

```text
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs
```

確認:

```sh
ls -lh \
  build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs
```

---

## 8. Linux起動

```sh
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=0 \
  SIM_EXTRA_ARGS=+TRACE_HEARTBEAT
```

トレースなしで実行する場合:

```sh
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-irqcause-min-initramfs \
  OPENSBI_CYCLES=0
```

---

## Troubleshooting

### `fw_jump.bin`がない

```text
FileNotFoundError:
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
```

OpenSBIを再生成します。

```sh
tools/build-opensbi.sh
```

---

### OpenSBIで`bool`エラー

```text
error: 'bool' cannot be defined via 'typedef'
note: 'bool' is a keyword with '-std=c23' onwards
```

GCC 15のC23既定モードとOpenSBI v1.3.1の互換性問題です。

OpenSBI用GCCへ次を付けます。

```text
-std=gnu11
```

`tools/build-opensbi.sh`のGCC wrapperで指定します。

---

### `cannot execute binary file`

```text
riscv64-unknown-linux-musl-gcc:
cannot execute binary file
```

Linux用に生成されたクロスコンパイラをmacOS上で直接実行しています。

BusyBoxのビルドはDocker内で実行します。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
tools/build-rv64imac-busybox.sh
```

---

### BusyBoxで`bzip2: not found`

```text
scripts/mkconfigs: bzip2: not found
```

BusyBoxをビルドするDocker imageへ `bzip2` を追加します。

```sh
apt-get install -y -qq \
  make \
  gcc \
  perl \
  file \
  bzip2 \
  bc \
  ca-certificates
```

---

### `missing BusyBox source`

```text
missing BusyBox source:
build/toolchain-src/busybox
```

BusyBox sourceを再取得します。

```sh
git clone https://git.busybox.net/busybox \
  build/toolchain-src/busybox

git -C build/toolchain-src/busybox checkout 1_36_1
```

---

### `missing musl source`

```text
missing musl source:
build/toolchain-src/musl
```

musl sourceを再取得します。

```sh
git clone https://git.musl-libc.org/git/musl \
  build/toolchain-src/musl
```

---

### `missing compiler`

```text
missing compiler:
build/riscv-musl-lp64/bin/riscv64-unknown-linux-musl-gcc
```

musl toolchainを再生成します。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
tools/build-rv64imac-musl-toolchain.sh
```

---

### `missing BusyBox binary`

```text
missing BusyBox binary:
build/busybox-out/rv64imac-lp64/busybox
```

BusyBoxを再生成します。

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
tools/build-rv64imac-busybox.sh
```

---

### `missing Linux source`

```text
missing Linux source:
build/external/linux
```

Docker volumeを使用する場合は、`LINUX_SRC`ではなく次を指定します。

```sh
LINUX_SRC_VOLUME=linux-6.12-src
```

volume確認:

```sh
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker volume ls | grep linux-6.12-src
```

---

## 推奨するclean target

通常の `make clean` では、Verilator生成物だけを削除する構成を推奨します。

```make
.PHONY: clean clean-all

clean:
	rm -rf $(OBJ_DIR)
	rm -rf $(INPUT_OBJ_DIR)
	rm -rf $(TRACE_OBJ_DIR)

clean-all:
	rm -rf $(OBJ_DIR)
	rm -rf $(INPUT_OBJ_DIR)
	rm -rf $(TRACE_OBJ_DIR)
	rm -rf build
```

通常は次を使います。

```sh
make clean
```

OpenSBI、toolchain、BusyBox、Linux Imageを含む `build/` 全体を削除するときだけ、次を使います。

```sh
make clean-all
```
