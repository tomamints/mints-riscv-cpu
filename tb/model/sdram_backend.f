// File list for RAM_BACKEND=sdram_model (C3 M3b): the CPU plus the SDRAM path.
// The SDRAM RTL declares a timescale; the default below covers the CPU files.
--timescale 1ns/1ps
-f core.f
rtl/bus/membus_sdram_adapter.sv
fpga/de0-cv/sdram/rtl/sdram_bridge64.sv
fpga/de0-cv/sdram/rtl/sdram_native16.sv
tb/model/sdram_cycle_model16.sv
tb/model/sdram_preloader.sv
