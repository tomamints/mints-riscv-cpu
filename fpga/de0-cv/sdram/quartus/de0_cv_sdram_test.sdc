create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_pll_clocks
derive_clock_uncertainty
create_generated_clock -name SDRAM_CLK -source [get_pins {clocking_block|u_pll|auto_generated|generic_pll2~PLL_OUTPUT_COUNTER|divclk}] -divide_by 1 [get_ports {DRAM_CLK}]
set dram_clock [get_clocks {SDRAM_CLK}]
if {[get_collection_size $dram_clock] != 1} { error "Expected one forwarded SDRAM PLL clock" }
set memory_period [get_clock_info -period $dram_clock]
set controller_clock [get_clocks {*generic_pll1~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $controller_clock] != 1 ||
    abs([get_clock_info -period $controller_clock]-$memory_period)>0.001 ||
    abs([lindex [get_clock_info -waveform $controller_clock] 0])>0.001} {
    error "Expected a matching zero-phase controller clock"
}
if {(abs($memory_period-20.0)>0.001 && abs($memory_period-50.0)>0.001) ||
    abs([lindex [get_clock_info -waveform $dram_clock] 0]-$memory_period/4.0)>0.001} {
    error "SDRAM clock must be 20/50MHz, quarter-cycle shifted"
}
# External timing envelope plus board-skew allowances. Output setup/hold
# include 1ns clock/data skew. Read max includes 2ns aggregate flight allowance.
set outputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_DQ[*] DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE DRAM_LDQM DRAM_UDQM}]
set_output_delay -clock $dram_clock -max 2.8 $outputs
set_output_delay -clock $dram_clock -min -1.8 $outputs
set_input_delay -clock $dram_clock -max 7.4 [get_ports {DRAM_DQ[*]}]
set_input_delay -clock $dram_clock -min 1.5 [get_ports {DRAM_DQ[*]}]
set_false_path -from [get_ports {KEY0_N}] -to [get_registers {*key_meta}]
set_false_path -to [get_ports {LEDR[*]}]
# JTAG status is sampled after the completion flag is stable. No control path
# crosses back into the memory clock domain.
set_clock_groups -asynchronous -group [get_clocks {CLOCK_50 *u_pll*}] -group [get_clocks {altera_reserved_tck}]
