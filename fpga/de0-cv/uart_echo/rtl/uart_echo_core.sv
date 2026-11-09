// uart_echo_core: byte echo buffer between an 8N1 RX event and an 8N1 TX
// valid/ready port, with diagnostics. Design: fpga/de0-cv/UART_BOARD_ECHO_DESIGN.md.
//
// * RX event (1 clk, no ready): pushed only if rx_fe == 0 and rx_bi == 0.
//   FE/BREAK bytes are never echoed; they are counted and flagged.
// * Push is accepted when count_after_pop < DEPTH, i.e. a full buffer still
//   accepts a byte in a cycle where a byte is popped. Otherwise the byte is
//   dropped, ovf_seen is set and ovf_cnt incremented.
// * TX: tx_valid = buffer not empty; one byte per tx_valid && tx_ready edge.
// * Counters saturate at all-ones. Flags/counters clear only on reset.
// * rst_n: active-low, asynchronous assert (release must be synchronized
//   outside).
module uart_echo_core #(
    parameter int unsigned DEPTH = 16,   // power of two, >= 2
    parameter int unsigned CNT_W = 16
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             rx_valid,
    input  logic [7:0]       rx_data,
    input  logic             rx_fe,
    input  logic             rx_bi,
    output logic             tx_valid,
    output logic [7:0]       tx_data,
    input  logic             tx_ready,
    output logic             fe_seen,
    output logic             bi_seen,
    output logic             ovf_seen,
    output logic [CNT_W-1:0] rx_ok_cnt,  // valid bytes received (incl. dropped by overflow)
    output logic [CNT_W-1:0] fe_cnt,     // framing errors that are not BREAK
    output logic [CNT_W-1:0] bi_cnt,     // BREAK events
    output logic [CNT_W-1:0] ovf_cnt,    // valid bytes dropped (buffer full)
    output logic [CNT_W-1:0] tx_cnt      // bytes handed to the transmitter
);

    localparam int unsigned PTR_W = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam int unsigned CNT_DEPTH_W = $clog2(DEPTH + 1);
    localparam logic [CNT_DEPTH_W-1:0] DEPTH_C = CNT_DEPTH_W'(DEPTH);

    // Elaboration-time parameter check for simulation/lint. Quartus 20.1 Lite
    // rejects $error in a generate block, so it is hidden from synthesis only.
    // synthesis translate_off
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_param_error
        $error("uart_echo_core: DEPTH must be a power of two >= 2 (DEPTH=%0d)", DEPTH);
    end
    // synthesis translate_on

    logic [7:0]             mem [DEPTH];
    logic [PTR_W-1:0]       rd_ptr;
    logic [PTR_W-1:0]       wr_ptr;
    logic [CNT_DEPTH_W-1:0] count;

    logic                   push_req;
    logic                   pop;
    logic [CNT_DEPTH_W-1:0] count_after_pop;
    logic                   push;
    logic                   overflow;

    assign tx_valid        = (count != '0);
    assign tx_data         = mem[rd_ptr];
    assign pop             = tx_valid && tx_ready;
    assign count_after_pop = count - {{(CNT_DEPTH_W-1){1'b0}}, pop};
    assign push_req        = rx_valid && !rx_fe && !rx_bi;
    assign push            = push_req && (count_after_pop < DEPTH_C);
    assign overflow        = push_req && !(count_after_pop < DEPTH_C);

    function automatic logic [CNT_W-1:0] sat_inc(input logic [CNT_W-1:0] v);
        return (&v) ? v : v + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (push) begin
            mem[wr_ptr] <= rx_data;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr    <= '0;
            wr_ptr    <= '0;
            count     <= '0;
            fe_seen   <= 1'b0;
            bi_seen   <= 1'b0;
            ovf_seen  <= 1'b0;
            rx_ok_cnt <= '0;
            fe_cnt    <= '0;
            bi_cnt    <= '0;
            ovf_cnt   <= '0;
            tx_cnt    <= '0;
        end else begin
            count  <= count_after_pop + {{(CNT_DEPTH_W-1){1'b0}}, push};
            rd_ptr <= rd_ptr + {{(PTR_W-1){1'b0}}, pop};
            wr_ptr <= wr_ptr + {{(PTR_W-1){1'b0}}, push};
            if (pop) begin
                tx_cnt <= sat_inc(tx_cnt);
            end
            if (push_req) begin
                rx_ok_cnt <= sat_inc(rx_ok_cnt);
            end
            if (overflow) begin
                ovf_seen <= 1'b1;
                ovf_cnt  <= sat_inc(ovf_cnt);
            end
            if (rx_valid && rx_bi) begin
                bi_seen <= 1'b1;
                bi_cnt  <= sat_inc(bi_cnt);
            end else if (rx_valid && rx_fe) begin
                fe_seen <= 1'b1;
                fe_cnt  <= sat_inc(fe_cnt);
            end
        end
    end

endmodule : uart_echo_core
