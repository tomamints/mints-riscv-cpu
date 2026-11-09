// uart_rx: 8N1 serial receiver (8 data bits, no parity, 1 stop, LSB first).
//
// Input: rxd is asynchronous; it passes a 2-FF synchronizer (reset value 0, so
// a line that is Low at reset is never mistaken for idle). All other logic is
// in the clk domain.
//
// Arming / start detection:
//   * While idle and divisor != 0, `armed` is set whenever the synchronized
//     line is High. While divisor == 0, `armed` is cleared every cycle, so a
//     High seen while disabled never qualifies a later Low as a start.
//   * A start is detected on the first idle cycle with armed && line Low &&
//     divisor != 0 (edge E0). Hence after enabling, the line must be seen High
//     (>= 1 clk with divisor != 0) and then Low. Enabling during a Low does not
//     accept that Low as a start.
//   * At E0 the channel's baud generator restarts and latches the divisor;
//     divisor changes after E0 (including to 0) affect only later frames.
//
// Sampling (single sample at the 16x bit centre, Tbit = 16*div/REF_HZ):
//   * start check after 8 ticks (half bit): if the line is High again the
//     start is rejected as a glitch (no event) and the receiver returns idle.
//   * data bit b (0..7) after 8 + 16*(b+1) ticks, stop after 8 + 16*9 ticks.
//   * Sample edges are E0 + ceil(K*CLK_HZ/REF_HZ) for K = (8+16*n)*div, i.e.
//     within [0,1) clk of the ideal grid anchored at E0. E0 itself is 2..3
//     clocks after the line edge (synchronizer latency + detect cycle).
//
// Event (no ready; the consumer cannot stall the receiver). Exactly one event
// per accepted start; rx_valid is a 1-clock pulse and rx_data, rx_frame_err,
// rx_break are updated on the same edge and held until the next event.
//   1. stop sample High                    -> event at stop centre, FE=0, BI=0.
//   2. stop sample Low, line was High at
//      some cycle since E0                 -> event at stop centre, FE=1, BI=0.
//   3. stop sample Low, line Low on every
//      cycle since E0 (data is 0x00)       -> BREAK-wait (RX_BRK), no event yet:
//      a. line seen High before 10 Tbit
//         after E0                         -> event when High is seen,
//                                             data=0x00, FE=1, BI=0.
//      b. line still Low on the sample edge
//         E0 + ceil(160*div*CLK/REF)       -> event there, data=0x00, FE=1, BI=1.
//   BREAK therefore needs >= 10 Tbit of continuous Low (measured on the
//   synchronized line from E0); in line time roughly Low > 10 Tbit + [0, 2) clk.
//
// Re-arm: after an event whose last observation was Low (case 2 with Low stop,
// case 3b) the receiver stays unarmed until the line is seen High for >= 1
// clock (with divisor != 0), so a held Low line produces exactly one event.
// Case 1 and 3a end with the line High, so the receiver is armed at once.
//
// rst_n (async, active-low) aborts any frame without an event and requires
// the line to be seen High (after the 2-FF delay) before a new start.
module uart_rx #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned REF_HZ = 3_686_400
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] divisor,
    input  logic        rxd,
    output logic        rx_valid,
    output logic [7:0]  rx_data,
    output logic        rx_frame_err,
    output logic        rx_break,
    output logic        rx_busy
);

    typedef enum logic [2:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP,
        RX_BRK
    } rx_state_t;

    // Synchronizer flops: constrain/identify as a synchronizer in the board SDC/QSF.
    logic        rxd_meta;
    logic        rxd_sync;

    rx_state_t   state;
    logic        armed;
    logic        saw_high;  // synchronized line seen High since E0
    logic [7:0]  shreg;
    logic [2:0]  bit_idx;
    logic [3:0]  os_cnt;
    logic        start_cond;
    logic        tick16;
    // Latched divisor is observation-only here (frame timing uses it inside u_baud).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] baud_div_latched;
    /* verilator lint_on UNUSEDSIGNAL */

    assign start_cond = (state == RX_IDLE) && armed && !rxd_sync && (divisor != 16'd0);
    assign rx_busy    = (state != RX_IDLE);

    uart_baud_gen #(
        .CLK_HZ(CLK_HZ),
        .REF_HZ(REF_HZ)
    ) u_baud (
        .clk            (clk),
        .rst_n          (rst_n),
        .restart        (start_cond),
        .divisor        (divisor),
        .tick16         (tick16),
        .divisor_latched(baud_div_latched)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxd_meta <= 1'b0;
            rxd_sync <= 1'b0;
        end else begin
            rxd_meta <= rxd;
            rxd_sync <= rxd_meta;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= RX_IDLE;
            armed        <= 1'b0;
            saw_high     <= 1'b0;
            shreg        <= '0;
            bit_idx      <= '0;
            os_cnt       <= '0;
            rx_valid     <= 1'b0;
            rx_data      <= '0;
            rx_frame_err <= 1'b0;
            rx_break     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            unique case (state)
                RX_IDLE: begin
                    if (divisor == 16'd0) begin
                        armed <= 1'b0;
                    end else if (start_cond) begin
                        state    <= RX_START;
                        armed    <= 1'b0;
                        saw_high <= 1'b0;
                        bit_idx  <= '0;
                        os_cnt   <= '0;
                    end else if (rxd_sync) begin
                        armed <= 1'b1;
                    end
                end

                RX_START: begin
                    if (rxd_sync) begin
                        saw_high <= 1'b1;
                    end
                    if (tick16) begin
                        if (os_cnt == 4'd7) begin
                            os_cnt <= '0;
                            if (rxd_sync) begin
                                // Start bit not Low at its centre: glitch, no event.
                                state <= RX_IDLE;
                                armed <= 1'b1;
                            end else begin
                                state <= RX_DATA;
                            end
                        end else begin
                            os_cnt <= os_cnt + 4'd1;
                        end
                    end
                end

                RX_DATA: begin
                    if (rxd_sync) begin
                        saw_high <= 1'b1;
                    end
                    if (tick16) begin
                        if (os_cnt == 4'd15) begin
                            os_cnt <= '0;
                            shreg  <= {rxd_sync, shreg[7:1]};
                            if (bit_idx == 3'd7) begin
                                state <= RX_STOP;
                            end else begin
                                bit_idx <= bit_idx + 3'd1;
                            end
                        end else begin
                            os_cnt <= os_cnt + 4'd1;
                        end
                    end
                end

                RX_STOP: begin
                    if (rxd_sync) begin
                        saw_high <= 1'b1;
                    end
                    if (tick16) begin
                        if (os_cnt == 4'd15) begin
                            os_cnt <= '0;
                            if (rxd_sync || saw_high) begin
                                // Cases 1 and 2: decided at the stop centre.
                                state        <= RX_IDLE;
                                rx_valid     <= 1'b1;
                                rx_data      <= shreg;
                                rx_frame_err <= !rxd_sync;
                                rx_break     <= 1'b0;
                                armed        <= rxd_sync;
                            end else begin
                                // Case 3: all Low so far; wait to 10 Tbit after E0.
                                state <= RX_BRK;
                            end
                        end else begin
                            os_cnt <= os_cnt + 4'd1;
                        end
                    end
                end

                RX_BRK: begin
                    if (rxd_sync) begin
                        // Case 3a: Low ended before 10 Tbit -> framing error only.
                        state        <= RX_IDLE;
                        os_cnt       <= '0;
                        rx_valid     <= 1'b1;
                        rx_data      <= 8'h00;
                        rx_frame_err <= 1'b1;
                        rx_break     <= 1'b0;
                        armed        <= 1'b1;
                    end else if (tick16) begin
                        if (os_cnt == 4'd7) begin
                            // Case 3b: Low for 160 ticks (10 Tbit) after E0.
                            state        <= RX_IDLE;
                            os_cnt       <= '0;
                            rx_valid     <= 1'b1;
                            rx_data      <= 8'h00;
                            rx_frame_err <= 1'b1;
                            rx_break     <= 1'b1;
                            armed        <= 1'b0;
                        end else begin
                            os_cnt <= os_cnt + 4'd1;
                        end
                    end
                end

                default: begin
                    state <= RX_IDLE;
                    armed <= 1'b0;
                end
            endcase
        end
    end

endmodule : uart_rx
