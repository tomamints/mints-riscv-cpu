# Test Status

This page distinguishes physical-board results, simulator results and historical
reference-model results. Documentation updates do not constitute a fresh run of
all regressions on the latest commit.

## Evidence summary

| Check | Recorded result | Scope / limitation |
|---|---|---|
| DE0-CV Linux 6.12 + BusyBox | Pass | Final 20 MHz board profile, 64 MiB SDRAM, normal `riscv_clocksource`, 100 Hz periodic ticks |
| MiNTs Life C application | Pass on board | Self-test, 1/100-generation benchmark checksums, four-generation UART demo, shell responsive after exit; native C also checked against independent Python model |
| Board GPIO / UIO | Pass for register access and application integration | Hardware ID, control readback, LED ownership, Life four-generation checksum and restoration; physical switch transitions/optical LED checks not performed |
| Physical UART interaction | Pass | Repeated commands at 115200 8N1, not just a shell banner |
| Board userspace checks | Pass | CPU loop, file create/read/remove, 1 MiB zero-data processing, sleep, response after 30 seconds idle |
| Board time progression | Short comparison passed | Linux 21.96 s vs host 21.92 s; not a precision calibration |
| VGA renderer / MMIO | Pass in simulation | All 307,200 visible pixels match a reference; sync, blanking, buffer ownership, reset and backpressure checked |
| VGA Linux clients | Pass for physical command/ack path | Self-test, demo, Life four-generation checksum, LED restoration and continued normal-clock operation; monitor image not observed |
| SD SPI / shared MMIO | Pass in simulation | All byte values, SDHC init/CMD17+CRC fixture, CS-high clocks, lanes, errors and reset; CPU board-path SD-SPI test passes |
| SD storage | Pass for physical FAT32 reads/new-file writes | SDHC recognition, whole/partition sector reads, mount/list/unmount; new 64 KiB file fsynced and verified after a read-only remount; power-cycle/loss durability untested |
| Board SPI polling optimization | Physical comparison | Initial sector-check command 85.279777 s → 5.679393 s; same content hash, includes kernel buffering/read-ahead |
| Private kernel-source view | Pass | Original sources preserved; repeatable private view and rejection of unexpected edits/context drift |
| File verifier | Host failure tests and physical RAM-file test pass | Independent pattern, overwrite/corruption/truncation/extra-data/symlink checks; 64 KiB file verified in RAM and on FAT32 after remount |
| Quartus implementation | Pass | 17,269 ALMs, all four corners pass setup/hold/recovery/removal at 20 MHz, 84 pins checked |
| JTAG image transfer | Pass | SD-enabled image's 608,569 words written and read back before CPU release |
| 64-bit timer probe | Pass on board | High bits, low-word rollover, monotonic reads and timer-compare expiry/clear |
| Verilator Linux autotest on M1 | Pass | `BUSYBOX-TEST-PASS` in the legacy simulator profile |
| Historical Whisper lockstep | Pass | BusyBox autotest reached after over 61 million architectural comparisons; not rerun for final FPGA profile |
| RV64 riscv-tests | 110/111 | `rv64mi-p-breakpoint` remains the only failure in the six RV64 suites |
| Directed RV64 regression | 7/7 | Machine configuration pointer, HPM access, retired-instruction counting, compressed trap value, `FENCE.I`, and supervisor trap-vector update |
| RV64 ACT4 | 225/357 | Verilator 5.046, with 131/132 unprivileged and 94/225 privileged tests passing |
| Seeded Sail comparison | 653/653 retire events across two workloads | M-mode retire PC and integer register writeback, including CSR readback and exception handling |
| JTAG mailbox / board-path simulation | Recorded passes | Request/acknowledgement, frozen snapshots, image verification/release and board self-test; configuration-specific |
| Delayed-memory `fence.i` regression | Recorded pass after store-drain fix | Directed posted-store/latency tests, distinct from ordinary zero/short-latency ISA tests |

Tested 250 Hz board configurations still showed loss of responsiveness. The
validated result is the 100 Hz profile, not a resolution of all 250 Hz cases.

The board passed continued-command testing on an initial candidate and again
with the final source-built kernel, ordinary boot arguments and canonical image
paths. No debug `initcall` prints or `clocksource=jiffies` override are required.

## Physical-board validation

Follow [the board guide](../fpga/de0-cv/soc/README.md). Expected behavior includes:

1. The loader verifies every image word before `CPU released`.
2. UART reaches a BusyBox shell and responds to `uname -a`.
3. `current_clocksource` reports `riscv_clocksource`.
4. Timer/serial interrupt counts increase; file and load commands complete.
5. Sleep and an idle interval do not prevent subsequent command responses.

A 1 MiB transfer from `/dev/zero` to `/dev/null` is a load check, not a complete
SDRAM test. The standalone SDRAM test and JTAG loaded-word verification have
different coverage. The board tests do not validate all possible memory contents,
interrupt schedules or workloads.

## Simulator Linux test

```sh
bash tools/rebuild-linux.sh all
bash tools/run-linux.sh
```

Require `BUSYBOX-TEST-PASS` without `BUSYBOX-TEST-FAIL` or a kernel panic.
The simulator autotest and physical interactive shell use different profiles.

## ISA and directed tests

The RV64 RTL implements `mconfigptr` as read-only zero, denies lower-privilege
HPM reads when the corresponding counter enable is clear, and counts
read-only `minstret` accesses as retired instructions. The `senvcfg` CSR
implements the FIOM bit. In the write-through configuration used in these tests,
`FENCE` waits for outstanding data transactions to finish, including
buffered stores. `FENCE.I` also invalidates the instruction cache.

After preparing the Linux Docker build image:

```sh
bash tools/setup-riscv-tests.sh
docker run --rm --init -v "$PWD:/repo" -w /repo mints-linux-verilator:5.046 \
  make test-rv64ui TEST_DIR=build/riscv-tests/isa TEST_OUT=build/test/isa
bash tools/test-fence-i-posted-store.sh
```

Run the directed RV64 CSR, compressed exception, trap-vector, and `FENCE.I`
checks in the same toolchain image.

```sh
docker run --rm --init -v "$PWD:/repo" -w /repo mints-linux-verilator:5.046 \
  make test-rv64-directed OBJ_DIR=build/rv64-directed/obj \
  TEST_BUILD_DIR=build/rv64-directed TEST_OUT=build/rv64-directed/results
```

The directed `fence.i` script uses a controlled memory-latency shim. It can also
exercise the SDRAM model path with `RAM_BACKEND=sdram_model`. These are separate
regressions, not prerequisites that the normal Linux rebuild automatically runs.

Native GPIO-client tests cover pause/resume, debounced reset, ID rejection and
SIGINT restoration using a file-backed register:

```sh
python3 tools/test-board-apps.py
```

Useful board-interface simulations:

```sh
bash tools/test-board-gpio.sh
bash tools/test-jtag-block-mailbox.sh
bash tools/test-de0cv-soc-sim.sh
bash tools/test-de0cv-uart.sh
bash tools/test-sdram-native16.sh
bash tools/test-sdram-bridge64.sh
```

## RV64 ACT4 and Sail

The runner uses upstream riscv-arch-test commit
`98a1ec7b0ae0373e25b015cb0f4bf8b0dd5f9924` and Sail 0.16 to generate
self-checking ELFs for the RV64IMAC simulator. The configuration covers M/S/U
mode and Sv39. The harness can stimulate software and timer interrupts.
External interrupt injection is outside the harness scope.
[riscv-arch-test](https://github.com/riscv/riscv-arch-test)

The outstanding unprivileged case is `M-remw-00`. The PMP suite passed 2 of
80 tests and accounts for most of the outstanding privileged cases.

```sh
bash tools/run-act4.sh
```

Set `ACT4_SUITES=Exceptions` to select just the exception suite. The generated
configuration, ELF hashes, and individual results are kept under
`build/act4/run.*/`. The runner reports reference generation and MiNTs
simulation exit codes independently.

For a short seeded M-mode comparison, replace the example path with the ACT4
output directory printed by the runner.

```sh
bash tools/test-rv64-differential.sh build/act4/run.ABC123
```

The comparison checks the order of retired PCs and integer register writes
through arithmetic, compressed instructions, loads/stores, CSR operations,
and exception return. The recorded workloads used seeds `20261126` and
`12345`. An optional second argument selects the seed. The assembly, ELF,
and traces are kept under `build/act4/differential.*/`.

## Historical architectural reference checks

Recorded simulator passes include 61,610,275 and 61,282,110 compared instructions
through the BusyBox autotest, from different checkpoints. The exact count is not
a required invariant. The integration compares architectural effects and
synchronizes timer/external interrupts and exceptions; it does not model FPGA
routing, board-level electrical timing or every asynchronous arrival schedule.

Whisper requires an external checkout/library and compatible Linux build
artifacts. It is not installed by the ordinary Linux rebuild. See
[Whisper integration](../tools/whisper_lockstep/README.md) and
[Linux baseline](LINUX_BASELINE.md).

## Not established by these tests

- General architectural certification or complete RVA23 compliance.
- Passing every RV64 architectural test. The legacy `rv64mi-p-breakpoint`
  failure and the remaining ACT4 failures are tracked in their respective suites.
- Long-duration board stability, 250 Hz board operation or a higher CPU clock.
- F/D/vector execution, SMP/coherence or a production Linux distribution.
- SD boot, power-cycle/power-loss durability, networking or a Linux graphical console on the board.
- A current board benchmark score or an FPGA-versus-simulator speedup ratio.

Generated test logs and local development records remain outside Git. Published
results summarize configuration-specific evidence and its limits.
