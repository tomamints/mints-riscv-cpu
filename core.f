# package / typedef 類
src/eei.sv
src/util.sv
src/inst_gen_pkg.sv
src/corectrl.sv

# interface
src/membus_if.sv
src/core_inst_if.sv
src/core_data_if.sv
src/aclint_if.sv

# small modules used by many places
src/fifo.sv
src/rvc_converter.sv

# major modules
src/memory.sv
src/aclint_memory.sv
src/plic.sv
src/alu.sv
src/brunit.sv
src/csrunit.sv
src/pmp_checker.sv
src/sv39_ptw.sv
rtl/mmu/tlb.sv
rtl/mmu/address_translation.sv
rtl/mmu/instruction_translation.sv
src/muldivunit.sv
src/memunit.sv
src/amounit.sv
src/uart_ns16550.sv
src/mmio_controller.sv
src/dma.sv
src/ram_arbiter.sv
src/inst_fetcher.sv
src/inst_decoder.sv
src/core.sv
src/top.sv
