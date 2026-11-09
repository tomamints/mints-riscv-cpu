module sdram_board_pll(input wire clock_50,output wire clk,dram_clk,locked);
    wire [5:0] clocks;
    reg [4:0] startup=0;
    always @(posedge clock_50) if(!(&startup)) startup<=startup+1'b1;
    altpll #(
        .intended_device_family("Cyclone V"),.operation_mode("NORMAL"),
        .inclk0_input_frequency(20000),.compensate_clock("CLK0"),
        .clk0_multiply_by(1),.clk0_divide_by(1),.clk0_phase_shift("0"),
        .clk1_multiply_by(1),.clk1_divide_by(1),.clk1_phase_shift("5000"),
        .port_clk0("PORT_USED"),.port_clk1("PORT_USED"),.port_locked("PORT_USED")
    ) u_pll(.inclk({1'b0,clock_50}),.areset(!(&startup)),.pllena(1'b1),.pfdena(1'b1),
        .clkena(6'b111111),.extclkena(4'b1111),.clk(clocks),.locked(locked));
    assign clk=clocks[0];
    assign dram_clk=clocks[1];
endmodule
