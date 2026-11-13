# RTL Layout

The current source list is `core.f`. Shared RTL lives in both `src/` and
`rtl/`; FPGA-specific files are under `fpga/de0-cv/`. Board build scripts
append their physical UART, SDRAM and JTAG integration files to the core list.

| Directory | Contents |
|---|---|
| `src/` | Pipeline, execution, CSRs/PMP, memory bus and simulator SoC |
| `rtl/cache/` | I/D-cache implementations |
| `rtl/mmu/` | TLB and instruction/data translation |
| `rtl/bus/` | CPU Membus-to-SDRAM adapter |
| `rtl/peripheral/` | 16550 registers and physical serial backend |
| `fpga/de0-cv/soc/rtl/` | Physical board SoC and top |
| `fpga/de0-cv/sdram/rtl/` | Native SDRAM controller, bridge and PLL |
| `fpga/de0-cv/rtl/` | UART PHY, loader and JTAG mailbox |
| `fpga/de0-cv/mem_probe/rtl/` | Synchronous byte-enable RAM primitive and synthesis probes |
| `tb/` | Verilator harnesses and SystemVerilog testbenches |
| `core/test/`, `tb/sw/` | Bare-metal and regression programs |
| `platform/` | Boot ROM, DTS files and kernel fragments |
| `tools/whisper_lockstep/` | Architectural reference integration |

## Important modules

| File | Role |
|---|---|
| `src/core.sv` | CPU pipeline integration |
| `src/inst_fetcher.sv` | Instruction fetch, translation/cache and prediction integration |
| `src/memunit.sv` | Load/store, translation and access sequencing |
| `src/sv39_ptw.sv` | Sv39 page-table walker |
| `rtl/mmu/tlb.sv` | Configurable associative TLB |
| `rtl/cache/icache.sv` | Configurable instruction cache |
| `rtl/cache/dcache.sv` | Data cache and store-buffer integration |
| `fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv` | Synchronous 64-bit RAM with byte enables |
| `src/branch_predictor.sv` | PHT, BTB and RAS prediction |
| `src/csrunit.sv` | Privileged CSRs, traps and interrupt state |
| `src/pmp_region_decode.sv` | PMP region decoding |
| `src/pmp_checker.sv` | Physical access checks |
| `src/aclint_memory.sv` | Software interrupt and timer registers |
| `src/plic.sv` | PLIC-compatible external interrupt controller |
| `src/uart_ns16550.sv` | Simulator UART backend |
| `rtl/peripheral/board_gpio_mmio.sv` | Board-only GPIO register and input synchronization |
| `rtl/peripheral/uart16550_serial.sv` | Physical serial UART integration |
| `rtl/bus/membus_sdram_adapter.sv` | Membus-to-SDRAM request/response path |
| `src/top.sv` | Simulator SoC top |
| `fpga/de0-cv/soc/rtl/de0cv_soc_core.sv` | Board SoC integration |
| `fpga/de0-cv/soc/rtl/de0cv_soc_top.sv` | Board PLL, pins and virtual JTAG wrapper |
| `tb/tb_verilator.cpp` | Main Verilator C++ harness |

Cache and TLB capacities are profile parameters. File locations do not imply
a fixed cache size; see [current configurations](CURRENT_STATUS.md).
