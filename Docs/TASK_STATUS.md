# Project Task Status

この文書は、現在どこまで実装・確認できていて、次に何をやるべきかを機能ごとに見るための進捗表です。

関連文書:

- `Docs/ROADMAP.md`: 何をどの順番で進めるか
- `Docs/TEST_STATUS.md`: 実際に走らせたテスト結果
- `Docs/S-modetest.md`: Supervisor-mode 検証チェックリスト
- `Docs/DMA.md`: DMA 実装メモ
- `Docs/RVA23_CHECKLIST.md`: RVA23方向の棚卸し
- `Docs/OPENSBI_BRINGUP.md`: OpenSBI banner / S-mode payload到達までの修正履歴
- `Docs/LINUX_MILESTONES.md`: Linuxが動いたと判断する条件と、対話shell後の確認項目
- `Docs/LINUX_TTY_UART_CURRENT_ISSUE.md`: Linux TTY/UART bring-upの直近原因と確認手順
- `Docs/LINUX_BASELINE.md`: Linux cmdloop baselineの固定手順、合格条件、trace方針
- `Docs/RTL_LAYOUT.md`: 将来のRTL配置、wrapper境界、段階移行方針
- `Docs/PERFORMANCE_COUNTERS.md`: CPI/stall/eventカウンタの使い方と現在の制限

## 現在地

短期目標だった「Linuxを起動するためのCPU」は、最初の大きな山を越えました。
現在は、Linuxが動くCPUを測定しながら高速化する段階です。

現在はここです。

```text
M-mode trap
  -> S-mode transition
  -> S-mode trap
  -> minimal SBI
  -> timer / interrupt
  -> PMP
  -> U-mode syscall
  -> Sv39
  -> OpenSBI
  -> Linux 6.12
  -> BusyBox initramfs
  -> BusyBox autotest
  -> Whisper lockstep pass
  -> performance tuning
```

OpenSBI v1.3.1、Linux 6.12.x、`rv64imac/lp64` soft-float static BusyBoxを使い、`autotest` initramfsで `BUSYBOX-TEST-PASS` まで到達済みです。
Whisper lockstepでも同じ到達点を検出し、約61.6M命令比較後に正常停止しています。

重要な前提として、ACLINTのtimer比較結果は `aclint.mtip -> mip.MTIP` に接続されています。`mideleg` だけでは `MTIP` は `STIP` に変換されないため、現在は M-mode timer handler が受けたMTIPをS-mode向けSTIPとして注入する経路を追加しています。将来的にはSstc実装も候補です。

## 優先順位

| Priority | Area | Why |
|---:|---|---|
| 1 | Lockstep BusyBox pass維持 | `BUSYBOX-TEST-PASS` までのWhisper同期を正しさのゲートにする |
| 2 | 性能計測基盤 | CPI、stall理由、TLB/cache/store buffer/arbiter countを測る |
| 3 | Phase 9 branch prediction | JALR BTBの100M測定、Whisper lockstep確認、RAS/larger BTBへ進むか判断 |
| 4 | MEM/cache追加改善 | D-cache容量/way/write-back、I/D memory pressureを測定結果で判断 |
| 5 | 通常shell化 | `setsid` / `cttyhack` / BusyBox対話shellの安定化 |

## 機能別ステータス

| Area | Status | 確認済みテスト | 次にやること |
|---|---|---|---|
| RV32/RV64基本実行 | Pass / current core suites | `make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full` | Linux向けには未対応拡張、CSR、deviceを追加確認 |
| debug MMIO output | Pass | `make test-output`, `make test-os2-min` | 標準UART互換デバイスへ寄せる |
| debug MMIO input | Pass / bring-up用 | `make test-input INPUT_TEXT=A`, `make test-os2-min-input INPUT_TEXT=Z` | 標準UART互換デバイスへ寄せる |
| DMA | Pass / experimental | `make test-dma` | interrupt連携、仕様整理、バスプロトコル整理 |
| M-mode trap | Pass / basic | `make test-mswi`, `make test-mtime` | illegal instruction / fault時の `mtval` とflushを確認 |
| S-mode transition | Pass | `make test-os2-min` | S-modeからM CSRアクセス時のillegal instruction確認 |
| S-mode trap | Pass / basic | `make test-os2-min-strap` | illegal instruction, ebreak, fault, `stval` を追加 |
| S-mode ecall delegation | Pass | `make test-os2-min-strap`, `make test-os2-min` | `medeleg[9]=0/1` の自動チェックを強める |
| Minimal SBI putchar | Pass | `make test-os2-min` | timer系SBIと同じdispatcherへ統合し続ける |
| SBI getchar | Pass | `make test-os2-min-input INPUT_TEXT=Z` | 将来のUART inputへ差し替えられる形を保つ |
| SBI timer | Pass / periodic basic | `make test-os2-min` | timer間隔やdeadline再設定方針を整理 |
| S-mode timer interrupt | Pass / periodic basic | `make test-os2-min` | interrupt中のSIE/SPIEを追加確認 |
| U-mode transition | Pass / minimal | `OS2_MIN_USER` | Linux最短では深追いしない。必要になったらU-mode stack分離やCSR faultを追加 |
| U-mode syscall | Pass / minimal | `OS2_MIN_USER` | Linux最短では深追いしない。自作OS検証時にsyscall番号、exit/putchar、trap frameを整理 |
| PMP | Pass / load/store/fetch fault basic | `make test-os2-min`, `make test-os2-min-input INPUT_TEXT=Z`, `make test-os2-min-strap`, `OS2_MIN_PMP` | MMIO副作用抑止確認、部分重複テスト、firmware領域保護 |
| Sv39 | Pass / basic data+fetch | `make test-os2-min-sv39` | `sv39_ptw.sv` をdata-sideとinstruction fetchから利用中。identity load/store/fetch、2MiB L1 / 1GiB L2 superpage、unmapped fault、SUM、MXR、A=0 load fault、D=0 store fault、W=0 store permission fault、satp.PPN切り替え、X=0 instruction page faultは確認済み。`Sv39Fault` で内部fault理由も追跡可能。PTW PTE read errorはaccess fault方針。次はPTW error発生源、TLB |
| PLIC | Pass / minimal RTL | `make c-test C_TEST=plic_uart_irq CYCLES=200000`, `make c-test C_TEST=plic_seip CYCLES=300000`, Linux BusyBox autotest | SiFive PLIC互換寄せの最小レイアウトを追加。base `0x0c000000`、32 sources、UART IRQ 10、M context 0、S context 1。priority / enable / threshold / claim-complete、UART THRE IRQ -> PLIC pending -> claim=10 -> `mip.MEIP` / `mip.SEIP` -> M-mode/S-mode external interruptを確認済み。Linux通常consoleとBusyBox autotestでも使用中 |
| Linux platform | Pass / BusyBox autotest | `make run-opensbi-input ... Image-linux-6.12-riscv64-busybox-autotest-initramfs`, `make run-opensbi-lockstep ...` | OpenSBIからLinux 6.12.xへhandoffし、PID 1 `/init` としてBusyBox autotestを実行。proc/sysfs/devtmpfs/tmpfs mount、`uname -a`、`ls /`、`pwd`、`mkdir`、tmpfs write/read、cleanupを確認し、`BUSYBOX-TEST-PASS` まで到達。Whisper lockstepでも `[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)` を確認 |

## テスト一覧

Linux起動を大目標にするため、U-mode syscallは最小確認済みで一旦区切ります。Sv39はdata-sideとinstruction fetchの最小identity mapping、2MiB L1 / 1GiB L2 superpage、SUM/MXR、A/D fault、X=0 fetch faultまで確認済みで、PTWは `sv39_ptw.sv` に分離済みです。OpenSBIはUART console / ACLINT MSWI / ACLINT MTIMERを認識し、S-mode payloadへhandoffできます。Linux 6.12.y Image投入後、`satp` WARLと`satp/sfence.vma` fetch flushを修正し、Linux earlyconのboot logまで到達しました。

Linux boot logの現在地:

- OpenSBI v1.3.1 `FW_JUMP` 起動
- `Platform Console Device : uart8250`
- `Platform IPI Device : aclint-mswi`
- `Platform Timer Device : aclint-mtimer @ 50000000Hz`
- Linux 6.12.97へS-mode handoff
- `SBI TIME/IPI/RFENCE extension detected`
- `earlycon: uart8250 at MMIO 0x10000000`
- reserved memory / zone setup / `riscv,isa` 認識
- virtual kernel memory layout
- `riscv-intc`
- `clocksource: riscv_clocksource`
- `sched_clock: 64 bits at 50MHz`
- `Console: colour dummy device 80x25`
- `Kernel command line: earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 ignore_loglevel`
- `devtmpfs: initialized`
- `pinctrl core: initialized pinctrl subsystem`
- `HugeTLB`
- `raid6`
- `SLUB`
- `RCU Tasks Trace`
- `NR_IRQS`

追加traceで分かったこと:

- `+TRACE_TIMER`: Linuxのclocksource初期化後、OpenSBIがACLINT `mtimecmp` を設定し、`mtime >= mtimecmp` で `MTIP` が立つ。OpenSBIが `mtimecmp = -1` に戻すことで `MTIP` がclearされる。
- `+TRACE_HEARTBEAT`: OpenSBIからLinuxへ移った後、`mode=1`、`satp=8000...`、`pc=ffffffff...` でLinux kernel textを実行している。
- `+TRACE_PIPE`: `sched_clock` 後もcommitが進んでいる。Linux側では `timekeeping_advance`、`ktime_get_update_offsets_now`、`do_irq`、spinlock周辺を実行し、M-mode側ではOpenSBIの `_trap_handler`、`sbi_timer_event_start`、`mtimer_event_start` に入る。現時点では完全停止ではなく、Verilator上で遅く進んでいる状態。
- timer frequency: `src/aclint_memory.sv` では `mtime` が毎CPUクロック増える。DTBが `timebase-frequency = 1000000` のままだと、50MHz想定CPUではLinux/OpenSBIから50倍速timerに見えるため、DTBを `50000000` へ合わせる。
- mul/div handshake: Linuxが `lib/string_helpers.c:string_get_size()` の `mul a5,a1,a0` 付近でloopしていた。`+TRACE_STRSIZE_REDUCE` と `+TRACE_STRSIZE_MULDIV` で確認したところ、対象MULのrequestがまだacceptされていないのに、前のmul/divの `rvalid/result` を現在の命令の完了として扱っていた。`exs_muldiv_accept` を明示し、request済みの命令だけが `rvalid` を完了として扱うように修正した。確認として `make c-test C_TEST=muldiv_string_size CYCLES=200000` と `make test-rv64um` がpassし、Linux上の `mul a5,a1,a0` は `wdata=0x200000` になった。

停止判定:

- `minstret` が増え続けるならCPUは命令をretireしており、少なくとも完全停止ではない
- Linuxログだけ止まる場合は、printkが出ない初期化中の可能性がある
- `minstret` が長時間増えない、または同一PCに固定されたら、そのPCを `System.map` / OpenSBI ELFで関数名に対応させて次の修正対象を決める
- 通常実行は `+TRACE_PIPE` なしを推奨する。`+TRACE_PIPE` はprintf量が多く、Linux起動を大きく遅くする

### Custom Tests

| Target | Status | 見ているもの |
|---|---|---|
| `make test-output` | Pass | debug MMIO output |
| `make test-input INPUT_TEXT=A` | Pass | debug MMIO input |
| `make test-dma` | Pass | DMA register設定とRAM-to-RAM copy |
| `make test-uart` | Pass | NS16550A互換UARTの最小polling TX。`0x10000005`のLSR read、`0x10000000`のTHR byte write、Verilator標準出力への表示 |
| `make test-uart-input INPUT_TEXT=Z` | Pass | NS16550A互換UARTの最小polling RX。stdinから来た `Z` を `RBR` で読み、`THR` へechoして表示。`LSR[0]=DR` とRBR readでのRX clearを確認 |
| `make test-uart-regs` | Pass | `IER/MCR/SCR/LCR`保持、`LCR.DLAB`による`DLL/DLM`切り替え、`LSR/IIR/MSR`の最小固定値 |
| `make test-uart-tx-irq` | Pass | UART `IER[1]` 有効化時の初回THRE IRQと、`THR` write後のTHRE IRQ再発火を確認。Linux 8250 driverが送信を継続するための前提 |
| `make test-uart-tx-seip` | Pass | S-mode PLIC contextで初回THRE IRQと `THR` write後のTHRE IRQ再発火を確認。Linux通常consoleのTX interrupt経路に近い |
| `make test-uart-rx-seip INPUT_TEXT=Z` | Pass | stdinから来た `Z` がUART RX interruptとしてPLIC S-context経由でS-modeへ届くことを確認。Enter入力でLinux UART handlerが起きるかの切り分け用 |
| `make c-test C_TEST=plic_uart_irq CYCLES=200000` | Pass | PLIC priority/enable/threshold readback、UART THRE interrupt、PLIC claim=10、M-mode external interrupt `mcause=0x800000000000000b` を確認 |
| `make c-test C_TEST=plic_seip CYCLES=300000` | Pass | M-modeでPMP allow-allと`mideleg.SEIP`を設定してS-modeへ入り、UART THRE interruptをPLIC S-contextでclaimし、S-mode external interrupt `scause=0x8000000000000009` を確認 |
| `make dtb` | Pass | `platform/riscv_cpu.dts` から `build/platform/riscv_cpu.dtb` を生成。RAMは128MiB、UART nodeは `serial@10000000`, `reg-shift=0`, `reg-io-width=1`。PLIC node `interrupt-controller@c000000` とUART IRQ 10も記述 |
| `make test-linux-bootargs` | Pass | Linux boot ABIの `a0=hartid=0`, `a1=0x87f00000` をpayloadへ渡し、RAM image内にDTBを配置 |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin` | Pass / OpenSBI platform info | OpenSBI `fw_jump.bin` を `0x80000000`、DTBを `0x87f00000`、任意Linux Imageを `0x80200000` に配置して起動するtarget。v1.3.1 `FW_JUMP` で `uart8250` console、`aclint-mswi` IPI、`aclint-mtimer @ 50000000Hz` timerを確認 |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=/private/tmp/linux-out/Image-linux-6.12-riscv64` | Historical / broad kernel image | Linux 6.12.y `Image` を `0x80200000` に配置し、OpenSBIからLinuxへhandoff。`Linux version 6.12.97`、Machine model、SBI Base/Time/IPI/RFENCE、`earlycon: uart8250`、memory init、SLUB、RCU、`riscv-intc`、`riscv_clocksource`、`sched_clock`、devtmpfs、pinctrl、DMA pool、HugeTLB、raid6 initまで確認。現在の通常検証は軽量BusyBox initramfsへ移行済み |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=/private/tmp/linux-out/Image-linux-6.12-riscv64-minbringup` | Pass / expected VFS panic | `allnoconfig` ベースのLinux 6.12.y bring-up用Image。約3MiB。SBI、DTB、RISC-V timer、SiFive PLIC、8250 UART console、proc/sysfs/devtmpfs、ELF/initrd周辺を残し、SCSI/ATA/MD/RAID6/USB/media/sound/PCI/ACPI/network/jitterentropyを削除。Linuxで `riscv-plic: ... mapped 32 interrupts`, `Serial: 8250/16550 driver`, `ttyS0 at MMIO 0x10000000`, `legacy console [ttyS0] enabled` を確認。rootfs未指定のため `VFS: Unable to mount root fs` で期待どおりpanic |
| `make run-opensbi OPENSBI_BIN=/path/to/fw_jump.bin LINUX_IMAGE_BIN=build/linux-out/Image-linux-6.12-riscv64-hello-initramfs` | Pass / expected PID1 panic | libcなし最小 `/init` をinitramfsへ埋め込み、LinuxがU-mode PID 1を起動し、`write(2)` syscallでconsole出力できることを確認。`exit(0)` でPID1終了panicになるのは期待結果 |
| `make run-opensbi-input OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-autotest-initramfs OPENSBI_CYCLES=0` | Pass / BusyBox autotest | `rv64imac/lp64` soft-float static BusyBoxをinitramfsへ入れ、Linux PID 1 `/init` からproc/sysfs/devtmpfs/tmpfs mount、`uname -a`、`ls /`、`pwd`、tmpfs file write/read、cleanupを実行し、`BUSYBOX-TEST-PASS` まで到達 |
| Docker `make run-opensbi-lockstep ... Image-linux-6.12-riscv64-busybox-autotest-initramfs` | Pass / Whisper lockstep | BusyBox autotest pass markerまでRTLとWhisperを同期。`[LOCKSTEP] PASS: 61610275 instructions compared (BusyBox autotest passed)` で自動停止 |
| `make test-opensbi-payload OPENSBI_BIN=/path/to/fw_jump.bin` | Pass | OpenSBIから `0x80200000` のS-mode payloadへ入り、`a0=hartid=0`, `a1=0x87f00000`, SBI Base call、SBI legacy console putcharを確認。PMPは8 entriesとしてOpenSBIに認識される |
| `make test-mswi` | Pass | machine software interrupt |
| `make test-mtime` | Pass | machine timer interrupt |
| `make test-os2-min` | Pass | S-mode遷移、SBI putchar、SBI set_timer、MTIPからSTIP注入、S-mode timer interrupt、periodic timer 3回 |
| `make test-os2-min-input INPUT_TEXT=Z` | Pass | SBI経由のdebug MMIO input |
| `make test-os2-min-strap` | Pass | `medeleg[9]=1`, S-mode ecallがS-mode `stvec` へ入る |
| `make test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=300000` | Pass | PMP禁止TOR領域へのS-mode load/store/fetchで `scause=5/7/1`, `stval=fault address`。禁止storeでRAM値が変化しないこと、fetchがRではなくXを見ること、32-bit命令後半2byteのX禁止も確認 |
| `make test-os2-min-sv39` | Pass | S-modeで`satp.MODE=8`を設定し、4KiB PTEの3-level page walkでdata load/store/fetchをidentity mapping。2MiB L1 / 1GiB L2 superpage、未map load、SUM=0/1、MXR=0/1、A=0 load、D=0 store、W=0 store、satp.PPN切り替え、X=0 fetch page faultを確認 |
| `make test-riscv-all TEST_TIMEOUT=20 TEST_OUT=results-full` | Pass / current claimed suites | `rv64mi-p-illegal`, `rv64mi-p-instret_overflow`, `rv64si-p-csr`, `rv64si-p-dirty` などの既知failは修正済み。F/D/Zb/Zfh系は未claim |

## Current Linux Bring-up Status

現在の大きな到達点は、OpenSBI経由でLinux 6.12.xを起動し、initramfs内のBusyBox `/init` で自動テストを最後まで通したことです。
対話shellは継続確認中ですが、CPU/SoCの回帰基準は `autotest` とWhisper lockstep passへ移しています。

確認済み:

- OpenSBI `fw_jump.bin` 起動
- DTB handoff `a0=hartid`, `a1=DTB PA`
- Linux Sv39有効化
- ACLINT timer / MSWI
- PLIC S-context
- NS16550A UART earlycon / normal console
- `rv64imac/lp64` soft-float static BusyBox
- Linux U-mode `/init` 実行
- BusyBox shell prompt
- `readloop-ttyS0` で `/dev/ttyS0` の行入力が `INPUT=...` と返ること
- `cmdloop-ttyS0` で `echo OK` が返ること
- `autotest` で `BUSYBOX-TEST-PASS` まで到達すること
- Whisper lockstepでBusyBox autotest passを検出し正常停止すること

残課題:

- BusyBox default `/init` の `/dev/ttyS0` + `setsid` + `cttyhack` 構成で対話shellを安定させる
- BusyBox上で `uname -a`, `ls /`, `cat /proc/cpuinfo`, `cat /proc/interrupts` などを確認する
- `ps`, `sleep`, background jobなどでprocess/schedulerを確認する
- 長期的にはBusyBox init/getty、rootfs、ブロックデバイス、より標準的なconsole/interrupt動作へ進める

### riscv-tests Summary

詳細は `Docs/TEST_STATUS.md` を参照します。

| Suite | Current |
|---|---|
| `rv32ui-p` | Pass |
| `rv32um-p` / `rv64um-p` | Pass |
| `rv32ua-p` / `rv64ua-p` | Pass |
| `rv32uc-p` / `rv64uc-p` | Pass |
| `rv32mi-p` / `rv64mi-p` | Pass |
| `rv32si-p` / `rv64si-p` | Pass |
| `rv64ui-p` | Pass |
| F/D/Zb/Zfh系 | Not claimed |

## 次の実装候補

### Option A: Linux-oriented UART / DTB

目的:

- Linux earlyconで使える標準寄りのUARTを用意する
- debug MMIOではなく、DTBに書けるplatform deviceとしてconsole経路を作る

作業:

- NS16550A基本8レジスタを実装する
- `LCR.DLAB` による `DLL/DLM` アクセスを保持する
- `IER/FCR/LCR/MCR/SCR` のread/write保持を確認する
- `IIR=no interrupt pending`, `LSR.THRE/TEMT=1` を返す
- DTBに `serial@10000000` を追加する
- `earlycon=uart8250,mmio,0x10000000` 相当でLinux early outputを狙う

完了条件:

- `make test-uart` がPass
- `make test-uart-regs` がPass
- `make dtb` がPass
- `make test-linux-bootargs` がPass
- `make run-opensbi OPENSBI_BIN=...` でOpenSBI UARTログを確認する
- UART初期化コードが `DLL/DLM/LCR/IER/FCR/MCR/SCR` に触っても止まらない
- DTBの `reg`, `reg-shift`, `reg-io-width` がRTLと一致する

### Option B: PMP / Access Control

目的:

- S-mode / U-modeから使えるRAM/MMIO範囲を定義する
- M-mode firmware領域をS-modeから保護する
- PMP fault時に副作用のあるmemory/MMIO requestを出さない

作業:

- PMP allow-all構成を作り、まず既存S-modeテストが壊れないことを確認する
- PMP禁止TOR領域へのS-mode load/storeでaccess faultになることを確認する
- 禁止storeでRAM値が変化しないことを確認する
- fault時にMMIO requestが発行されないことを確認する
- instruction fetchにもPMP X permissionを適用する
- RAM / debug MMIO / ACLINT のアクセス許可範囲を明文化する
- firmware text/dataをS-modeからアクセス禁止にする
- 部分重複、MMIO許可/禁止などのtrapを追加テストする

完了条件:

- `make test-os2-min` が引き続きPass
- 許可したRAM/MMIO accessが通る
- 禁止したfirmware領域accessがfaultになる
- 禁止fetchがinstruction access faultになる
- fetchがR permissionではなくX permissionを見ることを確認する
- 32-bit命令の後半2byteがPMP境界をまたぐfetch faultを確認する

### Option C: timer / interrupt

目的:

- S-mode OSが周期timerを使える前提を作る

作業:

- S-mode timer handler内で次回timerを再設定する
- periodic timerとして複数回割り込みを受ける
- interrupt中の `SIE/SPIE` と `sepc` 保存を確認する

完了条件:

- S-mode handlerでtimer interruptを受ける
- `scause` がinterrupt bit付きのtimer causeになる
- `sret` で元のS-mode処理へ戻る

### Option D: PMP / access control

目的:

- S-modeから使うRAM/MMIOを許可し、M-mode firmware領域を守る

作業:

- RAMをS/U-modeからread/write/execute可能にする
- debug MMIOまたは将来UARTをS-modeから使えるようにする
- firmware領域をS-modeから書けないようにする
- 禁止アクセスでtrapすることを確認する

完了条件:

- 許可領域アクセスは成功
- 禁止領域アクセスは期待したfaultになる

### Option E: U-mode transition

目的:

- 本来のsyscallを作る準備

作業:

- U-mode用entryを用意
- U-mode stackを用意
- `sstatus.SPP=U`
- `sepc=user_entry`
- `sret`

完了条件:

- U-mode codeが1文字出力、またはS-modeへ戻る合図を出せる
- U-modeからS/M CSRアクセスでtrapする

### Option F: U-mode syscall

目的:

- 本来の `syscall = U-mode -> S-mode` を確認する

作業:

- `medeleg[8]=1`
- S-mode `stvec` を設定
- U-mode appが `ecall`
- S-mode handlerが `a7/a0-a5` を読む

完了条件:

- `U-mode ecall -> S-mode trap -> sepc += 4 -> sret` で復帰
- `SYS_putchar`, `SYS_exit` が動く

## 判断メモ

- `medeleg[9]=1` のS-mode self-trapは検証には有用だが、SBI用途では使わない
- SBI用途では `medeleg[9]=0` として、S-mode `ecall` をM-modeへ上げる
- 本来のOS syscallは `medeleg[8]=1` として、U-mode `ecall` をS-modeへ上げる
- Linuxへ行く前に、SBI / timer / PMP / U-mode / Sv39 を小さいテストで潰す
- 現在のSv39はdata-sideとinstruction fetchの基本経路まで対応済み。Linux起動前にPTW error発生源、TLB/sfence方針を整理する
