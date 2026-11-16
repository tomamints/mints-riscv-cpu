create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
derive_clock_uncertainty

# Only the first flop of each synchronizer is excepted; the flop-to-flop
# stages (reset_meta -> reset_n, rxd_meta -> rxd_sync) stay timed.
# The collections below are asserted to be non-empty with exact counts by
# check_constraints.tcl (run after the compile flow).

# KEY0 is asynchronous and only drives the reset synchronizer (as in blink).
set_false_path -from [get_ports {KEY0_N}] -to [get_registers {*reset_meta* *reset_n*}]
# UART_RXD is an asynchronous serial input that enters only the PHY RX synchronizer.
set_false_path -from [get_ports {UART_RXD}] -to [get_registers {*u_rx|rxd_meta}]
# UART_TXD comes straight from the uart_tx txd register; the remote receiver is
# asynchronous (bit time 8.68 us), so no output delay is constrained.
set_false_path -from [get_registers {*u_tx|txd}] -to [get_ports {UART_TXD}]
# LEDs are human-visible indicators without timing requirements.
set_false_path -to [get_ports {LEDR[*]}]
