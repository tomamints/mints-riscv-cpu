module sdram_board_pll #(parameter int unsigned CLK_HZ=50_000_000)
    (input wire clock_50,output wire clk,dram_clk,locked);
    wire [5:0] clocks;
    localparam string MEMORY_PHASE_PS = CLK_HZ==20_000_000 ? "12500" : "5000";
    generate if(CLK_HZ!=20_000_000 && CLK_HZ!=50_000_000) begin : g_bad_clock
`ifdef VERILATOR
        initial $fatal(1,"sdram_board_pll: unsupported clock profile");
`else
        sdram_board_pll_unsupported_clock_profile reject_profile();
`endif
    end endgenerate
    reg [4:0] startup=0;
    always @(posedge clock_50) if(!(&startup)) startup<=startup+1'b1;
    altpll #(
        .intended_device_family("Cyclone V"),.operation_mode("NORMAL"),
        .inclk0_input_frequency(20000),.compensate_clock("CLK0"),
        .clk0_multiply_by(CLK_HZ==20_000_000 ? 2 : 1),
        .clk0_divide_by(CLK_HZ==20_000_000 ? 5 : 1),.clk0_phase_shift("0"),
        .clk1_multiply_by(CLK_HZ==20_000_000 ? 2 : 1),
        .clk1_divide_by(CLK_HZ==20_000_000 ? 5 : 1),
        .clk1_phase_shift(MEMORY_PHASE_PS),
        .port_clk0("PORT_USED"),.port_clk1("PORT_USED"),.port_locked("PORT_USED")
    ) u_pll(.inclk({1'b0,clock_50}),.areset(!(&startup)),.pllena(1'b1),.pfdena(1'b1),
        .clkena(6'b111111),.extclkena(4'b1111),.clk(clocks),.locked(locked));
    assign clk=clocks[0];
    assign dram_clk=clocks[1];
endmodule
