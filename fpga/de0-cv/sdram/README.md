# Native 16-bit SDR SDRAM controller

`fpga/de0-cv/sdram/rtl/sdram_native16.sv` provides a single outstanding halfword transaction,
byte write enables, explicit row closing and periodic refresh. It uses a fixed
`CLK_HZ=50000000` (default) or `CLK_HZ=20000000`, burst length 1 and CAS
latency 3. Initialization waits 200 us; refresh admission reserves 16 cycles
before a seven-microsecond target. Other clock profiles are rejected.

The memory clock samples registered command outputs a nominal quarter period
after the controller rising edge (5 ns at 50 MHz, 12.5 ns at 20 MHz).
Pin timing must be analyzed. This module does not generate that
clock, contain a PLL, provide board pin assignments or establish I/O timing.
Use a separately constrained board wrapper before programming hardware.

## Interface

- Hold `req_valid` and request fields stable until `req_ready` is sampled high
  on a rising edge. `req_addr` is a 25-bit **halfword offset**, not a CPU byte
  address. Mapping: row `[24:12]`, bank `[11:10]`, column `[9:0]`.
- `req_be[0]` enables the low byte; `[1]` enables the high byte. An all-zero
  mask still completes a write transaction without modifying data.
- Every accepted read or write produces one `rsp_valid` pulse after the row
  has closed. Read data accompanies the response; write response data is zero.
  There is no response backpressure.
- `dq_out` and `dq_oe` connect to a tristate buffer in the board wrapper;
  `dq_in` is the sampled memory input. Do not implement internal tristate nets.
- Active-low `rst_n` is the cold power initialization reset. It must not be
  driven by a normal pushbutton restart: the SDRAM device itself has no reset
  input. A cold power reset cancels pending work and starts initialization.
  `init_done` remains low during initialization. Reset does not preserve memory
  contents as an interface guarantee.
- `soft_reset` is a synchronous warm restart. It cancels replies, blocks new
  requests, safely completes the active memory command and keeps refresh running.
  Writes already performed are not rolled back. Memory contents are retained by
  the running controller. A board wrapper must synchronize the restart signal.
  A host must ignore any previously asserted response on the restart edge.

## Simulation

With Docker Desktop and the Verilator image from `Dockerfile.linux`:

```sh
bash tools/test-sdram-native16.sh
```

The runner checks the normal pin-model test and separately expects failures
when an illegal initialization command, corrupted read data or missing refresh
is injected.
Logs are in `build/test/sdram-native16/`. Previous runs are archived in
`build/test/archive/`. A simulation pass does not establish physical SDRAM
timing, retention, or CPU integration.

## Standalone 64-bit bridge

`fpga/de0-cv/sdram/rtl/sdram_bridge64.sv` serializes each aligned 64-bit request into four native
halfword operations. It accepts CPU byte addresses only in
`0x80000000..0x83fffff8`. Out-of-range or unaligned requests return
`rsp_error=1` without issuing a native operation. Reads assemble little-endian
halfwords; writes split eight byte enables into four pairs.

```sh
bash tools/test-sdram-bridge64.sh
```

This bridge has a standalone request/response interface. The integrated
[Linux SoC](../soc/README.md) connects it to the CPU through
`rtl/bus/membus_sdram_adapter.sv`; the bridge itself does not implement Membus.
CPU access sequencing and error propagation belong to the adapter/CPU path. Bridge and native controller
must share cold reset and synchronous `soft_reset` so abandoned replies cannot
be mistaken for new requests. Native replies must occur after acceptance,
never combinationally in the acceptance cycle.

## DE0-CV standalone hardware test

The board wrapper uses a PLL to forward the selected memory clock with a
quarter-period shift. It checks all 256 byte masks at the last word, then writes and reads
all 64 MiB using address-dependent data, its inverse, zeros and ones. Each
write sweep is followed by a one-second refresh/retention interval.

```sh
bash tools/build-de0cv-sdram-test-docker.sh
bash tools/build-de0cv-jtag-status.sh
bash tools/program-de0cv-sdram-test.sh
python3 tools/run-de0cv-sdram-test.py
```

Select the 20 MHz common-clock profile with
`SDRAM_CLK_HZ=20000000 bash tools/build-de0cv-sdram-test-docker.sh`.
The polling tool automatically allows 300 seconds for this slower full-memory
test; `--timeout` overrides it. The programming command prints the built clock profile.
Simulation runners accept the same `SDRAM_CLK_HZ` variable; their 20 MHz
logs use a `-20000000` suffix to preserve the default profile's output.

Requires the Quartus container/volume from `tools/setup-quartus.sh` and native
programmer dependencies from `tools/setup-de0cv-programmer.sh`. Programming
replaces the volatile FPGA configuration. USB-Blaster is sufficient; UART is
not used. LEDR4 indicates PASS, LEDR5 FAIL, LEDR3 memory initialization and
LEDR2 PLL lock. KEY0 restarts the test without resetting the SDRAM controller.

SDRAM pins use 3.3-V LVTTL with explicit 8 mA drive and fast slew. The
board model assumes 6 pF on clock/commands and 8 pF on DQ, including a
2 pF board allowance. These are conservative design assumptions rather than
measurements.

The SDC uses a conservative SDRAM timing envelope with additional assumed
board allowances: 1 ns clock/data skew for command setup/hold and 2 ns
aggregate read-flight allowance. These allowances have not been measured
on the board. The build checks all available FPGA timing corners, explicit
SDRAM read/output paths, and fitted pin locations/directions/I/O standards.
This standalone test does not establish CPU, cache, AMO or Linux correctness.

The JTAG-only reserved TDI/TMS/TDO ports are excluded from the unconstrained
port rejection. SDRAM ports and every clock must be constrained.
The polling tool requires observing the test in progress before accepting PASS;
`--accept-existing` reads a previously completed result without asserting freshness.
