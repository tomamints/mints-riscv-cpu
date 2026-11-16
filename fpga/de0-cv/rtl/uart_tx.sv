// uart_tx: 8N1 serial transmitter (8 data bits, no parity, 1 stop, LSB first,
// idle High). 8N1 only; LCR word-length/parity/stop settings are not supported.
//
// Byte interface (valid/ready):
//   * A byte is transferred on a rising edge where tx_valid && tx_ready are both
//     1. Only then is tx_data captured. A tx_valid/tx_data that is never seen
//     together with tx_ready is never transmitted.
//   * tx_ready = rst_n && idle && (divisor != 0). It is combinational from
//     registered state, rst_n and the divisor input; it does not depend on
//     tx_valid. After a transfer it is Low from the next cycle until the frame
//     (including the full stop bit) has ended.
//   * One transfer = one frame. A master that keeps tx_valid High after a
//     transfer is offering a NEW byte; it must drop tx_valid or present the
//     next byte in the cycle after the transfer edge to avoid a duplicate.
//
// Frame timing (Tbit = 16 * divisor_latched / UART_REF_HZ):
//   * txd falls (start bit) on the transfer edge itself (edge 0).
//   * Bit boundary k (k = 1..10) is on edge ceil(16*div*k*CLK_HZ/REF_HZ),
//     i.e. within [0, 1) clock of t0 + k*Tbit. Boundary 10 = end of stop bit,
//     where tx_busy falls.
//   * Back-to-back: tx_ready rises after the stop-bit end edge, so the next
//     start bit begins at least 1 clock after a full stop bit.
//   * The divisor is latched at the transfer edge; divisor changes during a
//     frame (including to 0) affect only later frames.
//
// tx_busy = frame in progress (start..stop). TEMT (16550) = TX FIFO empty &&
// !tx_busy. rst_n (async, active-low) aborts a frame: txd returns High at once.
module uart_tx #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned REF_HZ = 3_686_400
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] divisor,
    input  logic        tx_valid,
    input  logic [7:0]  tx_data,
    output logic        tx_ready,
    output logic        txd,
    output logic        tx_busy
);

    typedef enum logic [1:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t   state;
    logic [7:0]  shreg;
    logic [2:0]  bit_idx;
    logic [3:0]  os_cnt;    // 16x oversample ticks within the current bit
    logic        fire;
    logic        tick16;
    // Latched divisor is observation-only here (frame timing uses it inside u_baud).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] baud_div_latched;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        bit_end;

    assign tx_ready = rst_n && (state == TX_IDLE) && (divisor != 16'd0);
    assign fire     = tx_valid && tx_ready;
    assign tx_busy  = (state != TX_IDLE);
    assign bit_end  = tick16 && (os_cnt == 4'd15);

    uart_baud_gen #(
        .CLK_HZ(CLK_HZ),
        .REF_HZ(REF_HZ)
    ) u_baud (
        .clk            (clk),
        .rst_n          (rst_n),
        .restart        (fire),
        .divisor        (divisor),
        .tick16         (tick16),
        .divisor_latched(baud_div_latched)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= TX_IDLE;
            txd     <= 1'b1;
            shreg   <= '0;
            bit_idx <= '0;
            os_cnt  <= '0;
        end else begin
            if (state == TX_IDLE) begin
                if (fire) begin
                    state   <= TX_START;
                    txd     <= 1'b0;
                    shreg   <= tx_data;
                    bit_idx <= '0;
                    os_cnt  <= '0;
                end
            end else if (tick16) begin
                if (!bit_end) begin
                    os_cnt <= os_cnt + 4'd1;
                end else begin
                    os_cnt <= '0;
                    unique case (state)
                        TX_START: begin
                            state <= TX_DATA;
                            txd   <= shreg[0];
                            shreg <= {1'b0, shreg[7:1]};
                        end
                        TX_DATA: begin
                            if (bit_idx == 3'd7) begin
                                state <= TX_STOP;
                                txd   <= 1'b1;
                            end else begin
                                bit_idx <= bit_idx + 3'd1;
                                txd     <= shreg[0];
                                shreg   <= {1'b0, shreg[7:1]};
                            end
                        end
                        TX_STOP: begin
                            state <= TX_IDLE;
                            txd   <= 1'b1;
                        end
                        default: begin
                            state <= TX_IDLE;
                            txd   <= 1'b1;
                        end
                    endcase
                end
            end
        end
    end

endmodule : uart_tx
