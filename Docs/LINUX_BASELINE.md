# Linux Cmdloop Baseline

Last updated: 2026-08-13

この文書は、MiNTs-CPU の Linux bring-up を次の性能改善へ進める前に固定するための baseline 手順です。

目的は、traceや一時的な診断コードに依存せず、同じRTL、DTB、OpenSBI、Linux Imageで、毎回同じ操作が通ることを確認することです。

現在の主回帰基準は `autotest` initramfs とWhisper lockstepの `BUSYBOX-TEST-PASS` です。
この文書の `cmdloop-ttyS0` は、手動入力やTTY挙動を確認するための補助baselineとして残します。

主回帰基準:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
  OPENSBI_CYCLES=0
```

lockstep回帰基準:

```bash
DOCKER_HOST=unix://$HOME/.colima/riscv-build/docker.sock \
docker run --rm \
  -v "$PWD:/work" \
  -w /work \
  riscv-lockstep-verilator:5.046 \
  bash -lc '
    rm -rf obj_dir_lockstep &&
    make build-lockstep &&
    make run-opensbi-lockstep \
      OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
      OPENSBI_ELF=build/external/opensbi/build/platform/generic/firmware/fw_jump.elf \
      LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs \
      OPENSBI_CYCLES=0
  '
```

期待する終了ログ:

```text
[LOCKSTEP] BusyBox autotest pass detected compared_order=...
[LOCKSTEP] PASS: ... instructions compared (BusyBox autotest passed)
```

## Baseline Scope

このbaselineで固定する範囲:

```text
MiNTs-CPU RTL
-> OpenSBI fw_jump
-> DTB
-> Linux 6.12.x Image
-> BusyBox initramfs
-> /init
-> cmdloop-ttyS0
-> UART input/output
```

合格条件は、対話shellの完成ではありません。まずは `cmdloop-ttyS0` で、TTY read、コマンド分岐、procfs、基本的なuserland実行が安定していることを確認します。

## Known Good Artifacts

現在の基準Image:

```text
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs
```

OpenSBI:

```text
build/external/opensbi/build/platform/generic/firmware/fw_jump.bin
```

DTB:

```text
build/platform/riscv_cpu.dtb
```

DTBの `model` は `MiNTs-CPU` です。DTSを変更した後は、実行前に必ず `make dtb` でDTBを更新します。

## Build Preconditions

RTLを変更した場合:

```bash
make build-input
```

DTSを変更した場合:

```bash
make dtb
```

Linux Imageを変更した場合は、変更理由、Image名、Kconfig差分、initramfs modeを記録してから実行します。baseline確認中は、古いtrace入りImageとnotrace Imageを混ぜないでください。

## Run Command

traceなしで実行します。

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=0
```

`SIM_EXTRA_ARGS=+TRACE...` は付けません。

## Ready Point

次が出たら入力待ちです。

```text
Run /init as init process
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

ここで止まって見えるのは正常です。`MARK-B` は `/dev/ttyS0` の `read()` 待ちを意味します。

## Baseline Test Sequence

入力は、まず1行ずつ待って行います。各コマンドで次の `MARK-B` が戻るまで次を入力しません。

```text
echo OK
echo OK
echo hello
uname
cat /proc/interrupts
cat /proc/cpuinfo
```

各コマンドの合格形:

```text
MARK-C: read returned
status=0
line=[...]
...
MARK-B: before read
```

`echo OK` の合格形:

```text
MARK-C: read returned
status=0
line=[echo OK]
OK
MARK-B: before read
```

## Failure Criteria

次が出た場合はbaseline失敗として扱います。

```text
[I pid=...]
[UART ...]
[PLIC ...]
scause=8000000000000009 が claim=0 と繰り返される
MARK-C が戻らない
入力文字がRBRで読まれるがecho/TXが止まる
次の MARK-B が戻らない
kernel oops / panic
```

ただし、`MARK-B` 後に何も出ない状態は入力待ちなので失敗ではありません。

## Artifact Record

baselineを固定するときは、最低限これを保存します。

```bash
shasum -a 256 \
  build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  build/platform/riscv_cpu.dtb
```

あわせて記録するもの:

```text
git status --short
git diff --stat
実行コマンド
入力したコマンド列
最後まで通ったログ
```

完全に固定できたら、tagを切ります。

```bash
git tag linux-baseline
```

tagを切るのは、不要traceが消えており、baseline sequenceが複数回通った後です。

## Trace Policy

baseline確認では、traceを足して原因を探さないでください。まずnotraceで再現するか確認します。

失敗した場合だけ、失敗区間に応じて最小traceを使います。

TXで止まる場合:

```text
+TRACE_TXUART
+TRACE_IRQ10PLIC
```

外部割り込みstormを疑う場合:

```text
PLIC claim/complete ID
UART irq source
csr mip/sip SEIP bit
```

TTY readが戻らない場合:

```text
queue_work return
worker_thread
flush_to_ldisc
n_tty_receive_buf_common
n_tty_read return
```

広いtrace、常時trace、1イベントで大量MMIO writeするtraceはbaseline確認では使いません。
