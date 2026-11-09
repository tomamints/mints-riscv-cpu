create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty
# The pushbutton is asynchronous and only drives the reset synchronizer.
set_false_path -from [get_ports {KEY0_N}] -to [get_registers {*reset_meta* *reset_n*}]
# An LED has no external synchronous receiver or output timing requirement.
set_false_path -to [get_ports {LEDR0}]
