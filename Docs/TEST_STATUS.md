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
| Quartus implementation | Pass | 17,123 ALMs, all four corners pass setup/hold/recovery/removal at 20 MHz, 80 pins checked |
| JTAG image transfer | Pass | VGA image's 515,864 words written and read back before CPU release |
| 64-bit timer probe | Pass on board | High bits, low-word rollover, monotonic reads and timer-compare expiry/clear |
| Verilator Linux autotest on M1 | Pass | `BUSYBOX-TEST-PASS` in the legacy simulator profile |
| Historical Whisper lockstep | Pass | BusyBox autotest reached after over 61 million architectural comparisons; not rerun for final FPGA profile |
| Reported ISA regression | 110/111 | Known `rv64mi-p-breakpoint` failure; not a claim that every ISA test passes |
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

After preparing the Linux Docker build image:

```sh
bash tools/setup-riscv-tests.sh
docker run --rm --init -v "$PWD:/repo" -w /repo mints-linux-verilator:5.046 \
  make test-rv64ui TEST_DIR=build/riscv-tests/isa TEST_OUT=build/test/isa
bash tools/test-fence-i-posted-store.sh
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
- Passing every privileged ISA test; the breakpoint failure remains known.
- Long-duration board stability, 250 Hz board operation or a higher CPU clock.
- F/D/vector execution, SMP/coherence or a production Linux distribution.
- Persistent storage, networking or a Linux graphical console on the board.
- A current board benchmark score or an FPGA-versus-simulator speedup ratio.

Generated test logs and local development records remain outside Git. Published
results summarize configuration-specific evidence and its limits.
