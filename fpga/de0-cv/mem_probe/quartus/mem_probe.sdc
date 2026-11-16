# 5 ns request only to obtain an Fmax report; the probe has no timing target.
create_clock -name clk -period 5.000 [get_ports {clk}]
derive_clock_uncertainty
