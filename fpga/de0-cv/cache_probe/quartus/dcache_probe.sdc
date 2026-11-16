# 20 ns (50 MHz) request; the probe reports register-to-register Fmax only.
create_clock -name clk -period 20.000 [get_ports {clk}]
derive_clock_uncertainty
