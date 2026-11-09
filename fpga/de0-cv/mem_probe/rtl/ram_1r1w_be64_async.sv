// ram_1r1w_be64_async: comparison model with the same capacity and the same
// byte-write port as ram_1r1w_be64, but a COMBINATIONAL read (latency 0), i.e.
// the style of the current cache data arrays. Used only to measure the resource
// difference in the Quartus probe; it is not a candidate for the CPU.
//
// Timing: rdata = mem[raddr] continuously (same cycle). `re` is accepted for
// port compatibility but has no effect (there is no read register to enable).
// Writes: identical to ram_1r1w_be64 (sampled at the rising edge, wbe per byte).
module ram_1r1w_be64_async #(
    parameter int unsigned DEPTH = 128
) (
    input  logic                     clk,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [7:0]               wbe,
    input  logic [63:0]              wdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic                     re,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [63:0]              rdata
);

    logic [7:0][7:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) begin
            if (wbe[0]) mem[waddr][0] <= wdata[ 7: 0];
            if (wbe[1]) mem[waddr][1] <= wdata[15: 8];
            if (wbe[2]) mem[waddr][2] <= wdata[23:16];
            if (wbe[3]) mem[waddr][3] <= wdata[31:24];
            if (wbe[4]) mem[waddr][4] <= wdata[39:32];
            if (wbe[5]) mem[waddr][5] <= wdata[47:40];
            if (wbe[6]) mem[waddr][6] <= wdata[55:48];
            if (wbe[7]) mem[waddr][7] <= wdata[63:56];
        end
    end

    assign rdata = mem[raddr];

endmodule : ram_1r1w_be64_async
