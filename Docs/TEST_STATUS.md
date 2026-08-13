# Test Status

Last updated: 2026-08-13

この文書は `core/test/share` にある riscv-tests 由来の test binary を、現在の simulator で実行した結果です。

実行日: 2026-08-11

## 実行方法

```sh
make test-suite SUITE=<suite> TEST_TIMEOUT=20
make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full
```

例:

```sh
make test-rv32ui TEST_TIMEOUT=20
make test-rv64ui TEST_TIMEOUT=20
```

## 注意

この表は「現在の test binary が pass したか」を示します。命令セットとして正式に実装済みであることを常に意味するものではありません。

特に `F`, `D`, `Zb*`, `Zfh` 系は、現状の SystemVerilog 実装に専用 decoder / execution unit が見当たらないため、pass していても正式サポートとは扱いません。trap handler や test binary 側の条件により pass している可能性があります。

現時点で実装から見て主張しやすい範囲は `RV64IMAC`、M/S/U privilege、Sv39、PMP、ACLINT、PLIC、NS16550A UART、ITLB/DTLB、I-cache、D-cache、store bufferです。

## Summary

| Suite | Result | Status |
|---|---:|---|
| `rv32ui-p` | 42 / 42 | Pass |
| `rv32um-p` | 8 / 8 | Pass |
| `rv32ua-p` | 10 / 10 | Pass |
| `rv32uc-p` | 1 / 1 | Pass |
| `rv32mi-p` | 16 / 16 | Pass |
| `rv32si-p` | 6 / 6 | Pass |
| `rv64ui-p` | 54 / 54 | Pass |
| `rv64um-p` | 13 / 13 | Pass |
| `rv64ua-p` | 19 / 19 | Pass |
| `rv64uc-p` | 1 / 1 | Pass |
| `rv64mi-p` | 17 / 17 | Pass |
| `rv64si-p` | 7 / 7 | Pass |

## Known Failures

今回確認した `rv32/rv64 ui/um/ua/uc/mi/si` の `-p` suite に既知failはありません。

直近で修正した既知fail:

- `rv64ui-p-ma_data`
- `rv64mi-p-illegal`
- `rv64mi-p-instret_overflow`
- `rv64si-p-csr`
- `rv64si-p-dirty`

### Unsupported / Not Claimed

These suites are outside the currently claimed implementation scope and were not part of the latest `make test-riscv-all` core-suite run:

- `rv32uf-p`
- `rv32ud-p`
- `rv32uzba-p`
- `rv32uzbb-p`
- `rv32uzbc-p`
- `rv32uzbs-p`
- `rv32uzfh-p`
- `rv64uf-p`
- `rv64ud-p`
- `rv64uzba-p`
- `rv64uzbb-p`
- `rv64uzbc-p`
- `rv64uzbs-p`
- `rv64uzfh-p`
- `rv64mzicbo-p`
- `rv64ssvnapot-p`
- `rv64uziccid-p`

## Current Support Estimate

| Area | Support estimate |
|---|---|
| RV32I user tests | Good: all `rv32ui-p` pass |
| RV64I user tests | Good: all `rv64ui-p` pass |
| RV32M / RV64M | Good: all tested M extension cases pass |
| RV32A / RV64A | Good: all tested A extension cases pass |
| RVC | Basic support: `rv32uc-p` and `rv64uc-p` pass |
| Machine privilege tests | Good for current `rv32mi-p` / `rv64mi-p` tests |
| Supervisor privilege tests | Good for current `rv32si-p` / `rv64si-p` tests |
| Floating point | Not claimed |
| Bitmanip / Zb* | Not claimed |
| Cache block / address translation extensions | Not claimed |
| DMA | Implemented experimentally, basic C test passes |
| UART | WIP: NS16550A compatible minimal polling TX, LSR, basic register hold, DLAB, and THRE interrupt pass |
| PLIC | WIP: SiFive-compatible minimal PLIC, UART IRQ 10, claim/complete, M-mode external interrupt, and S-mode external interrupt pass |
| PMP | WIP: 8 entries, allow-all, S-mode load/store/fetch access fault, blocked store side-effect, and OpenSBI PMP domain payload fetch tests pass |
| Sv39 | WIP: data/fetch 3-level 4KiB identity mapping, satp.PPN switch, L1/L2 superpage, load/store/instruction page fault, SUM, MXR, A/D fault pass |
| Linux | Pass: OpenSBI -> Linux 6.12 -> BusyBox autotest -> `BUSYBOX-TEST-PASS` |
| Whisper lockstep | Pass to BusyBox autotest marker: 61,610,275 compared instructions |

## Custom C Tests

`core/test/*.c` は `Makefile` から build / run できます。

| Target | Source | Result | Notes |
|---|---|---:|---|
| `make test-output` | `core/test/debug_output.c` | Pass | `Hello,world!` と success まで到達 |
| `make test-input INPUT_TEXT=A` | `core/test/debug_input.c` | Pass as manual I/O test | `A` を入力すると `B` が返る。self-terminating test ではなく cycle count で終了する |
| `make test-dma` | `core/test/debug_dma.c` | Pass | DMA register 設定、RAM-to-RAM copy、結果検証、success まで到達 |
| `make test-uart` | `core/test/uart_output.c` | Pass | NS16550A互換UARTの `LSR` をpollingし、`THR` へbyte writeして `A` とsuccessを出力。`0x10000000`のMMIO decode、byte lane read/write、Verilator標準出力を確認 |
| `make test-uart-input INPUT_TEXT=Z` | `core/test/uart_input.c` | Pass | `ENABLE_DEBUG_INPUT`付きsimulatorでstdinの `Z` をUART `RBR` から読み、`THR` へechoして `Z` とsuccessを出力。`LSR[0]=DR`、RBR readでのRX clearを確認 |
| `make test-uart-regs` | `core/test/uart_regs.c` | Pass | `LSR.THRE/TEMT`, `IIR=0x01`, `MSR=0`, `IER/MCR/SCR/LCR`保持、`LCR.DLAB`による`DLL/DLM`切り替えを確認 |
| `make test-uart-tx-irq` | `core/test/uart_tx_irq.c` | Pass | UART `IER[1]` 有効化時の初回THRE IRQに加えて、`THR` へbyte writeした後にTHRE IRQが再発火することを確認。Linux 8250 driverの送信継続に近い経路のテスト |
| `make test-uart-tx-seip` | `core/test/uart_tx_seip.c` | Pass | S-mode PLIC contextで、初回THRE IRQと `THR` write後のTHRE IRQ再発火を確認。Linux通常consoleのTX interrupt経路に近い |
| `make test-uart-rx-seip INPUT_TEXT=Z` | `core/test/uart_rx_seip.c` | Pass | `ENABLE_DEBUG_INPUT`付きsimulatorでstdin `Z` を受け取り、UART RX interruptがPLIC S-context経由でS-mode external interruptへ届き、handlerで `IIR=0x04` と `RBR=Z` を確認 |
| `make c-test C_TEST=plic_uart_irq CYCLES=200000` | `core/test/plic_uart_irq.c` | Pass | PLIC priority/enable/threshold readback、UART `IER[1]` によるTHRE interrupt、PLIC claim=10、M-mode external interrupt `mcause=0x800000000000000b` を確認 |
| `make c-test C_TEST=plic_seip CYCLES=300000` | `core/test/plic_seip.c` | Pass | M-modeでPMP allow-allと`mideleg.SEIP`を設定してS-modeへ入り、UART `IER[1]` によるTHRE interruptをPLIC S-contextでclaimし、S-mode external interrupt `scause=0x8000000000000009` を確認 |
| `make run-opensbi-input LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs OPENSBI_CYCLES=0` | Linux 6.12.y + BusyBox autotest initramfs | Pass | `rv64imac/lp64` soft-float static BusyBoxをinitramfsへ埋め込み、LinuxがPID 1 `/init` を実行。proc/sysfs/devtmpfs/tmpfs mount、`uname -a`、`ls /`、`pwd`、`mkdir`、tmpfs write/read、cleanupを実行し、`BUSYBOX-TEST-PASS` まで到達 |
| `make run-opensbi-lockstep LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs OPENSBI_CYCLES=0` | Linux 6.12.y + BusyBox autotest + Whisper | Pass | Docker上の `riscv-lockstep-verilator:5.046` で実行。`BUSYBOX-TEST-PASS` をUART出力から検出し、`[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)` で自動停止 |
| `make test-mswi` | `core/test/mswi.c` | Pass | ACLINT machine software interrupt の handler 到達を確認 |
| `make test-mtime` | `core/test/mtime.c` | Pass | ACLINT machine timer interrupt の handler 到達を確認 |
| `make test-os2-min` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | 入力不要の統合テスト。PMP NAPOT allow-all設定後、S-mode遷移、SBI debug console putchar、SBI TIME `set_timer`、MTIPからSTIP注入、S-mode timer interrupt、periodic timer 3回を確認 |
| `make test-os2-min-input INPUT_TEXT=Z` | `core/test/os2_min/kernel.c`, `tests.c` | Pass | S-modeから最小SBI dispatcher経由で debug console getchar を呼び、入力文字 `Z` を取得して出力 |
| `make test-os2-min-strap` | `core/test/os2_min/kernel.c` | Pass | `medeleg[9]` 設定後に S-mode `ecall` が `stvec` へ入り、handler で `sepc += 4` して `sret` で復帰することを確認 |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=300000` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c`, `firmware.c`, `sbi.c` | Pass | PMP entry1のTOR禁止領域へS-modeからload/store/fetchし、loadは`scause=5`、storeは`scause=7`、fetchは`scause=1`、いずれも`stval=fault address` でS-mode trapへ入ること、禁止storeで保護wordが変化しないことを確認。fetchは`X=1/R=0/W=0`で成功、`R=1/W=1/X=0`でfaultすること、32-bit命令後半2byteがX禁止領域に入るとfaultすることも確認 |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_USER OS2_MIN_NAME=kernel_user CYCLES=120000` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c` | Pass | S-modeから`sstatus.SPP=U`、`sepc=user_entry`、`sret`でU-modeへ入り、U-mode `ecall` が`scause=8`でS-mode trapへ入ること、1回目のsyscall戻り値でU-modeへ復帰できること、2回目をexit syscallとして処理できることを確認 |
| `make test-os2-min-sv39` | `core/test/os2_min/kernel.c`, `tests.c`, `trap.c` | Pass | S-modeで3段page tableを作成し、`satp.MODE=8`でdata-sideとfetch-sideのSv39を有効化。identity load/store/fetch、2MiB L1 / 1GiB L2 superpage、未map load page fault、SUM=0/1、MXR=0/1、A=0 load fault、D=0 store fault、W=0 store permission fault、satp.PPN切り替え、X=0 instruction page faultを確認 |

## Platform Build Tests

| Target | Source | Result | Notes |
|---|---|---:|---|
| `make dtb` | `platform/riscv_cpu.dts` | Pass | 最小DTBを生成。RAM `0x80000000/0x08000000`、UART `serial@10000000`、`reg-shift=0`、`reg-io-width=1`、PLIC `interrupt-controller@c000000`、UART IRQ 10、earlycon bootargsを記述 |
| `make test-linux-bootargs` | `platform/bootrom_linux.S`, `platform/bootargs_check.S`, `platform/riscv_cpu.dts` | Pass | bootromが `a0=0`, `a1=0x87f00000` を設定して `0x80000000` へジャンプし、payloadが受け取れることを確認 |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin` | external OpenSBI binary | Pass / platform info | OpenSBI v1.3.1 `FW_JUMP` を `0x80000000`、DTBを `0x87f00000` に配置して起動。`uart8250` console、`aclint-mswi` IPI、`aclint-mtimer @ 50000000Hz` timer、`Next Address=0x80200000`、`Next Arg1=0x87f00000`、`Next Mode=S-mode` を確認 |
| `make test-opensbi-payload OPENSBI_BIN=/path/to/fw_jump.bin` | `platform/opensbi_payload_entry.S`, `platform/opensbi_payload.c` | Pass | OpenSBIから `0x80200000` のS-mode payloadへhandoffし、payload側で `hartid=0`, `dtb=0x87f00000`, SBI Base spec `0x01000000`, SBI legacy console putcharを確認。最後にdebug MMIOへsuccessを書いて終了 |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=/private/tmp/linux-out/Image-linux-6.12-riscv64-minbringup` | Linux 6.12.y minbringup Image | Pass / expected VFS panic | `riscv-plic` driverがPLICを認識、8250 driverが `ttyS0 at MMIO 0x10000000` を登録し、通常consoleを有効化。rootfs/initramfs未指定のため `VFS: Unable to mount root fs` で期待どおりpanic |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=build/linux-out/Image-linux-6.12-riscv64-hello-initramfs` | libcなし最小 `/init` | Pass / expected PID1 panic | `platform/linux_user_init.S` をinitramfsへ埋め込み、LinuxがPID 1としてU-mode `/init` を実行。`write(2)` で `Hello from userspace...` が出力され、`exit(0)` 後にPID1終了panicになることを確認 |
| `tools/build-rv64imac-busybox.sh` | BusyBox 1.36.1 | Pass | `riscv64-unknown-linux-musl-gcc` でstatic BusyBoxを生成。`ELF64`, `RVC`, `soft-float ABI`, `statically linked` を確認し、F/D命令が混入していないことをobjdumpで確認 |
| `tools/build-linux-busybox-initramfs-image.sh` | Linux source in Docker volume | Pass | macOS filesystemの `Kbuild/kbuild` 衝突を避けるため `LINUX_SRC_VOLUME=linux-6.12-src` を使用。`INIT_SCRIPT_MODE` ごとにBusyBox入り `Image-linux-6.12-riscv64-busybox-$INIT_SCRIPT_MODE-initramfs` を生成 |

debug MMIO output の重複表示は、`mmio_controller` が device `valid` を response まで出し続けていたことが原因でした。現在は device `ready` で request を issue 済みにし、以後は `rvalid` だけ待つため、debug output / DMA test とも重複なしで pass します。

Linux通常consoleで `BusyBox userspac` の16文字だけ表示されて止まる問題は、16550のTHR empty interruptが再発行されず、Linux 8250 driverがFIFOサイズ分だけ送信して次のTX interrupt待ちになっていたことが原因でした。`src/uart_ns16550.sv` でTHR write後に `IER[1]` が有効なら `tx_irq_pending` を再度立てるように修正しています。その後、THRE pendingはIIR readまたはTHR writeでclearする16550互換動作へ寄せ、PLIC claim/complete後にSEIP stormが残らないことを確認しました。さらにCSR側ではSEIPをCSR writable bitとして内部ラッチしないようにし、PLIC外部信号で決まるread-only相当の扱いに整理しています。

Whisper lockstepでは、非retire同期例外、MTIMER/SEIPのone-shot injection、WFI中断時のEPC補正、instruction fetch page faultのSTVAL補正を入れ、BusyBox autotestの `BUSYBOX-TEST-PASS` まで同期済みです。

S-mode `sepc` 更新失敗は、CSR write mask table に `SEPC` がなく `wmask=0` になっていたことが原因でした。現在は `SEPC_WMASK` を適用し、S-mode trap handler から `sepc` を更新できます。
