// uart_baud_gen: per-channel 16x oversample enable generator (no generated clock).
//
// Rate model (16550-compatible):
//   reference enable  : UART_REF_HZ on average, derived from CLK_HZ by a phase
//                       accumulator (acc += REF_HZ, wrap at CLK_HZ).
//   tick16            : one pulse every `divisor` reference enables.
//   baud              : REF_HZ / (16 * divisor).
//
// Exactness: the accumulator never truncates the REF_HZ / CLK_HZ ratio, so the
// n-th reference enable after `restart` occurs on clock edge ceil(n*CLK_HZ/REF_HZ)
// (counting the restart edge as edge 0). Every tick16 edge is therefore late by
// [0, 1) clock periods versus the ideal time; the error does not accumulate.
//
// Timing contract:
//   * tick16 is combinational from registered state. A consumer that sees
//     tick16 == 1 during a cycle acts on the next rising edge; that edge is the
//     ideal-grid edge described above.
//   * restart (synchronous, 1 clk is enough): at that edge acc and the divisor
//     sub-counter are cleared and `divisor` is latched into divisor_latched.
//     tick16 is forced low while restart is high.
//   * A latched divisor of 0 produces no ticks (generator frozen) until the
//     next restart with a non-zero divisor.
//   * Changes on `divisor` without restart have no effect (mid-frame safety).
//   * rst_n (active-low, asynchronous assert) clears everything, latched
//     divisor = 0. No other restart/reset source exists.
//
// Parameters: requires 0 < REF_HZ < CLK_HZ (at most one reference enable per
// clock) and CLK_HZ < 2**31.
module uart_baud_gen #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned REF_HZ = 3_686_400
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        restart,
    input  logic [15:0] divisor,
    output logic        tick16,
    output logic [15:0] divisor_latched
);

    // acc < CLK_HZ always, acc + REF_HZ < 2*CLK_HZ <= 2**ACC_W.
    localparam int unsigned ACC_W = $clog2(CLK_HZ) + 1;
    localparam logic [ACC_W-1:0] CLK_C = ACC_W'(CLK_HZ);
    localparam logic [ACC_W-1:0] REF_C = ACC_W'(REF_HZ);

    // Elaboration-time parameter check for simulation/lint. Quartus 20.1 Lite
    // rejects $error in a generate block, so it is hidden from synthesis only.
    // synthesis translate_off
    if (REF_HZ == 0 || REF_HZ >= CLK_HZ || CLK_HZ >= 32'h8000_0000) begin : g_param_error
        $error("uart_baud_gen: require 0 < REF_HZ < CLK_HZ < 2**31 (REF_HZ=%0d CLK_HZ=%0d)",
               REF_HZ, CLK_HZ);
    end
    // synthesis translate_on

    logic [ACC_W-1:0] acc;
    logic [ACC_W-1:0] acc_sum;
    logic             ref_hit;
    logic [15:0]      div_q;
    logic [15:0]      sub_cnt;   // invariant: sub_cnt < div_q whenever div_q != 0
    logic             sub_last;

    assign acc_sum  = acc + REF_C;
    assign ref_hit  = (acc_sum >= CLK_C);
    assign sub_last = (sub_cnt == (div_q - 16'd1));
    assign tick16   = !restart && (div_q != 16'd0) && ref_hit && sub_last;
    assign divisor_latched = div_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc     <= '0;
            div_q   <= '0;
            sub_cnt <= '0;
        end else if (restart) begin
            acc     <= '0;
            div_q   <= divisor;
            sub_cnt <= '0;
        end else if (div_q != 16'd0) begin
            if (ref_hit) begin
                acc <= acc_sum - CLK_C;
                if (sub_last) begin
                    sub_cnt <= '0;
                end else begin
                    sub_cnt <= sub_cnt + 16'd1;
                end
            end else begin
                acc <= acc_sum;
            end
        end
    end

endmodule : uart_baud_gen
