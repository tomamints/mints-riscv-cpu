`timescale 1ns/1ps
module de0_cv_blink #(
    parameter int unsigned HALF_PERIOD_CYCLES = 25_000_000
) (
    input  logic CLOCK_50,
    input  logic KEY0_N,
    output logic LEDR0
);
    localparam int unsigned COUNT_WIDTH =
        HALF_PERIOD_CYCLES > 1 ? $clog2(HALF_PERIOD_CYCLES) : 1;
    // KEY0 asserts reset asynchronously; release passes through two flops.
    (* async_reg = "true" *) logic reset_meta;
    (* async_reg = "true" *) logic reset_n;
    logic [COUNT_WIDTH-1:0] count;

    always_ff @(posedge CLOCK_50 or negedge KEY0_N) begin
        if (!KEY0_N) begin
            reset_meta <= 1'b0;
            reset_n <= 1'b0;
        end else begin
            reset_meta <= 1'b1;
            reset_n <= reset_meta;
        end
    end

    always_ff @(posedge CLOCK_50 or negedge reset_n) begin
        if (!reset_n) begin
            count <= '0;
            LEDR0 <= 1'b0;
        end else if (count == COUNT_WIDTH'(HALF_PERIOD_CYCLES - 1)) begin
            count <= '0;
            LEDR0 <= !LEDR0;
        end else begin
            count <= count + 1'b1;
        end
    end
endmodule
