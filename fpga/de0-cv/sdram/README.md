# Native 16-bit SDR SDRAM controller

`rtl/sdram_native16.sv` provides a single outstanding halfword transaction,
byte write enables, explicit row closing and periodic refresh. It uses a fixed
50 MHz controller clock, burst length 1 and CAS latency 3.

The memory clock must sample the registered command outputs half a controller
period after the controller rising edge. This module does not generate that
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
- Active-low reset cancels pending work and starts a new initialization.
  `init_done` remains low during initialization. Reset does not preserve memory
  contents as an interface guarantee.

## Simulation

With Docker Desktop and the Verilator image from `Dockerfile.linux`:

```sh
bash tools/test-sdram-native16.sh
```

The runner checks the normal pin-model test and separately expects failures
when an illegal initialization command or corrupted read data is injected.
Logs are in `build/test/sdram-native16/`. Previous runs are archived in
`build/test/archive/`. A simulation pass does not establish physical SDRAM
timing, retention, or CPU integration.
