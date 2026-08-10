# MiNTs-CPU Whisper Lockstep 導入・再現マニュアル

最終更新: 2026-08-11

この文書は、自作 SystemVerilog RISC-V CPU（MiNTs-CPU）を Tenstorrent Whisper と instruction-by-instruction lockstep させ、OpenSBI → Linux → BusyBox autotest まで検証した流れを、後から再現できるようにまとめたものです。

> 最終到達点
>
> ```text
> [LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
> [LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
> ```

## 1. 目的と構成

```text
RTL MiNTs-CPU
  ↓ retire trace
tb_verilator.cpp
  ↓
tools/whisper_lockstep/WhisperRef.cpp
  ↓
Tenstorrent Whisper ISS
  ↓
1命令ごとに architectural state を比較
```

検証範囲は、OpenSBI → Linux → /init → BusyBox autotest → BUSYBOX-TEST-PASS までです。

Whisper repository:

```text
https://github.com/tenstorrent/whisper
```

## 2. ディレクトリ構成

CPUプロジェクトrootは以下です。

```bash
$HOME/risc-v-cpu
```

主要構成:

```text
~/risc-v-cpu/
├── Makefile
├── core.f
├── src/
│   ├── top.sv              # core_top module
│   ├── tb_verilator.cpp
│   ├── amounit.sv
│   ├── csrunit.sv
│   └── ...
├── tools/
│   └── whisper_lockstep/
│       ├── WhisperRef.hpp
│       └── WhisperRef.cpp
├── whisper/
│   ├── Hart.cpp
│   ├── Hart.hpp
│   ├── System.cpp
│   ├── virtual_memory/
│   ├── pci/
│   └── build-Linux/
│       └── librvcore.a
├── obj_dir_lockstep/
│   └── sim
└── build/
    └── external/
        ├── opensbi/
        │   └── build/platform/generic/firmware/
        │       ├── fw_jump.bin
        │       └── fw_jump.elf
        └── linux-out/
            └── Image-linux-6.12-riscv64-busybox-autotest-initramfs
```

重要: Whisperは別の場所ではなく、

```text
~/risc-v-cpu/whisper
```

に置きます。Makefileのlockstep buildがこの位置を前提にしています。

## 3. Whisperをcloneする

```bash
cd "$HOME/risc-v-cpu"

git clone https://github.com/tenstorrent/whisper.git whisper
```

確認:

```bash
ls whisper
```

`Hart.cpp`, `Hart.hpp`, `System.cpp`, `virtual_memory`, `pci` などが見えればOKです。

## 4. Linux/Dockerを使う

今回のlockstep環境は、macOS host上からDocker/ColimaのLinux環境を使う構成です。

使用Docker image:

```text
riscv-lockstep-verilator:5.046
```

Verilator:

```text
5.046
```

Colima socket:

```bash
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock
```

## 5. Whisper library

lockstep buildが参照するlibrary:

```text
whisper/build-Linux/librvcore.a
```

確認:

```bash
cd "$HOME/risc-v-cpu"

test -f whisper/build-Linux/librvcore.a \
  && echo "Whisper library OK" \
  || echo "Whisper library missing"
```

Whisperの `Hart.cpp` などを変更した場合は、この `librvcore.a` も再ビルドする必要があります。

Whisper本家READMEの一般的なbuildは `whisper` directoryで `make` 系ですが、今回のプロジェクトで必要なのは最終的に `build-Linux/librvcore.a` が存在することです。

## 6. lockstep adapter

追加したbridge:

```text
tools/whisper_lockstep/WhisperRef.hpp
tools/whisper_lockstep/WhisperRef.cpp
```

比較対象:

```text
PC
privilege
rd write enable
rd number
rd data
memory valid
load/store
virtual address
physical address
access size
store data
trap / interrupt boundary
trap cause / trap value
CSR-visible effects through later reads and trap state
```

## 7. Makefileターゲット

主要ターゲット:

```bash
make build-lockstep
make run-opensbi-lockstep
```

生成物:

```text
obj_dir_lockstep/sim
```

追加simulator argumentの変数は必ず:

```text
SIM_EXTRA_ARGS
```

です。`EXTRA_SIM_ARGS` ではありません。

## 8. Docker内でlockstep build

```bash
cd "$HOME/risc-v-cpu"

DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    rm -rf obj_dir_lockstep
    make build-lockstep
  '
```

## 9. OpenSBI / Linux / BusyBox image

OpenSBI BIN:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
```

OpenSBI ELF:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.elf
```

Linux + BusyBox autotest image:

```text
build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs
```

最終bootで使ったLinuxは6.12.x系です。

## 10. 基本のfull lockstep実行

```bash
cd "$HOME/risc-v-cpu"

DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    make build-lockstep &&
    make run-opensbi-lockstep \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES=0
  ' 2>&1 | tee /tmp/lockstep.log
```

## 11. `OPENSBI_CYCLES=0`

これは0 cycleで終了ではなく、cycle上限なしです。

現在はBusyBox autotestのPASS markerをtestbench側で検出し、

```text
BUSYBOX-TEST-PASS
```

に到達すると正常終了できます。

最終ログ:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## 12. 特定範囲だけ詳細trace

```bash
SIM_EXTRA_ARGS="+LOCKSTEP_TRACE_START=62865815 +LOCKSTEP_TRACE_END=62865845"
```

完全例:

```bash
cd "$HOME/risc-v-cpu"

DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    make build-lockstep &&
    make run-opensbi-lockstep \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES=0 \
      SIM_EXTRA_ARGS="+LOCKSTEP_TRACE_START=62865815 +LOCKSTEP_TRACE_END=62865845"
  ' 2>&1 | tee /tmp/lockstep-trace.log
```

`LOCKSTEP_TRACE_END` はtrace出力終了位置であって、simulation終了位置ではありません。

## 13. fetch trace

```bash
SIM_EXTRA_ARGS="+TRACE_FETCH_FAULT"
```

例:

```text
[FETCH] ptw fault va=00000000000101b8 cause=12 ...
```

特定PC周辺だけに絞る場合:

```bash
SIM_EXTRA_ARGS="+TRACE_FETCH_FAULT +TRACE_FETCH_FAULT_PC=101b8"
```

全fetch eventを見る場合は `+TRACE_FETCH_ALL` ですが、ログ量が非常に多いため通常は使いません。

## 14. AMO / LR-SC trace

```bash
SIM_EXTRA_ARGS="+TRACE_AMO_RESERVATION"
```

特定アドレスだけなら:

```bash
SIM_EXTRA_ARGS="+TRACE_AMO_RESERVATION +TRACE_AMO_ADDR=24e711c4"
```

別アドレスのSCがreservationを消すか確認したい場合は、最初は `TRACE_AMO_ADDR` を外します。

## 15. ログの見方

成功進捗:

```text
[LOCKSTEP] passed 61000000 instructions pc=...
```

mismatch:

```text
[LOCKSTEP-MISMATCH] order=...
```

差分として `pc`, `privilege`, `rd_data`, `mem_write`, `mem_addr` などが表示されます。

## 16. exception同期

Linuxではretireしないtrap transitionが大量にあります。

ログ:

```text
[LOCKSTEP-EXPT-EVENT]
[LOCKSTEP-EXPT-SYNC]
```

主なcause:

```text
8  = ECALL from U-mode
12 = Instruction Page Fault
13 = Load Page Fault
15 = Store/AMO Page Fault
```

## 17. interrupt同期

RTLが実際にinterruptを受理したarchitectural boundaryで、Whisperへone-shot injectします。

MTIMER:

```text
cause=7
[LOCKSTEP-MTIMER-EVENT]
[LOCKSTEP-MTIMER-INJECT]
```

SEIP:

```text
cause=9
[LOCKSTEP-SEIP-INJECT]
```

raw interrupt levelを毎stepコピーするのではなく、accepted eventを1回だけinjectするのが重要です。

## 18. これまでlockstepで直した主な問題

### Failed SC retire trace
失敗したSCがmemory writeしたように見える問題を修正。

```text
SC fail → rd != 0, mem_write = 0
```

### LR/SC reservation
trap、別SC、retryを含むreservation stateをRTL/Whisperで合わせた。

### Zaamo
AMO old/new valueとretire memory traceを正確化。

### PMP
Whisper側のPMP実装数をRTLの8 entry構成へ合わせた。

### HPM CSR
未実装HPM CSRをread-zero / write-ignoreへ合わせた。

### MISA
RTL visible MISA:

```text
0x8000000000141105
```

へWhisper architectural stateを同期。

### TIME CSR
Whisperのinstruction-count系時間ではなくRTL TIME値をdestination registerへ同期。

### translated MMIO VA/PA
例:

```text
VA = 0xffffffc604001000
PA = 0x10000000
```

`retire_mem_addr` をVA、`retire_mem_pa` をPAとして分離。

### misaligned / split access
page跨ぎ、split storeなどのretire mask/dataをarchitectural accessとして正確化。

### Instruction Page Fault STVAL
代表例:

```text
RTL STVAL = 0x101b8
REF STVAL = 0x101bc
```

原因は8-byte fetch block baseとactual architectural PCの混同。

```text
fetch block base = 0x101b8
actual PC        = 0x101bc
```

修正後は `cause=12 value=0x101bc` で一致。

### precise trap / interrupt boundary
MEPC/SEPC/STVAL/MTVALや、interruptが「どのinstructionの前に入ったか」をRVCの2-byte境界も含めて合わせた。

## 19. CPU / SoC構成

```text
ISA: RV64IMAC
M/S/U mode
Sv39
PMP
PLIC
ACLINT
NS16550A UART
initramfs
BusyBox static userspace
```

主要memory map:

```text
RAM   0x80000000 - 0x87ffffff  (128 MiB)
Linux 0x80200000
DTB   0x87f00000
UART  0x10000000
ACLINT 0x02000000
PLIC  0x0c000000
```

## 20. BusyBox autotest

最終correctness milestone:

```text
OpenSBI boot
→ Linux boot
→ /init
→ BusyBox
→ uname
→ ls
→ pwd
→ mkdir
→ file write
→ file read
→ cleanup
→ BUSYBOX-TEST-PASS
```

最終結果:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=61610274
[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)
```

## 21. 普段使うコマンドだけ抜粋

### project root

```bash
cd "$HOME/risc-v-cpu"
```

### Whisper clone

```bash
git clone https://github.com/tenstorrent/whisper.git whisper
```

### Whisper library確認

```bash
test -f whisper/build-Linux/librvcore.a && echo OK
```

### clean lockstep build

```bash
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    rm -rf obj_dir_lockstep
    make build-lockstep
  '
```

### full Linux + BusyBox lockstep

```bash
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    make build-lockstep &&
    make run-opensbi-lockstep \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES=0
  ' 2>&1 | tee /tmp/lockstep.log
```

## 22. トラブルシュート

### `SIM_EXTRA_ARGS` が効かない

```bash
grep -n -C 5 -E 'SIM_EXTRA_ARGS|run-opensbi-lockstep|obj_dir_lockstep/sim' Makefile
```

### `$test$plusargs` が効かない

`src/tb_verilator.cpp` に以下があるか確認:

```cpp
Verilated::commandArgs(argc, argv);
```

### hostでsimが動かない

lockstep simulatorはDocker/Linux側で実行する。Mac hostから `obj_dir_lockstep/sim` を直接実行しない。

## 23. correctnessとperformanceを分離する

Correctness:

```text
riscv-tests
Whisper lockstep
Linux + BusyBox autotest
```

Performance:

```text
RTL cycle
minstret
CPI / IPC
internal PERF counters
CoreMark等
```

Whisperの実行速度はCPU性能指標には使わない。

## 24. 新しいPCで再構築するときの最短順序

```text
1. CPU repoを ~/risc-v-cpu に置く
2. cd ~/risc-v-cpu
3. Whisperを ./whisper にclone
4. Docker / Colimaを準備
5. riscv-lockstep-verilator:5.046 imageを利用可能にする
6. whisper/build-Linux/librvcore.a を用意
7. OpenSBIをbuild
8. Linux + BusyBox autotest imageをbuild
9. make build-lockstep
10. make run-opensbi-lockstep
11. BUSYBOX-TEST-PASSを確認
12. [LOCKSTEP] PASSを確認
```

## 25. PASS状態を保存する

CPU repo revision:

```bash
git rev-parse HEAD
```

Whisper revision:

```bash
git -C whisper rev-parse HEAD
```

Docker image確認:

```bash
docker image inspect riscv-lockstep-verilator:5.046
```

tag例:

```bash
git tag linux-whisper-lockstep-pass
```

## 26. 現時点で完全に復元できていない部分

過去ログから確実に確認できたのは、

```text
~/risc-v-cpu/whisper
whisper/build-Linux/librvcore.a
riscv-lockstep-verilator:5.046
make build-lockstep
make run-opensbi-lockstep
OpenSBI/Linux image paths
SIM_EXTRA_ARGS
WhisperRef
最終61,610,275 instruction PASS
```

です。

一方、`riscv-lockstep-verilator:5.046` Docker imageを最初に作成した完全な `docker build` コマンドは、今回参照できた過去ログだけでは確定できていません。ここだけは現在のDockerfile/Makefileを確認して追記するのが安全です。

また、Whisperには今回のRTLへ合わせたローカル修正が複数入っているため、最新masterをcloneしただけでは61M PASS状態をそのまま再現できない可能性があります。PASSしたCPU repo revisionとWhisper revisionをセットで保存してください。
