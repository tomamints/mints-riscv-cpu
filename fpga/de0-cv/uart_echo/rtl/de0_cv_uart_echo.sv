// de0_cv_uart_echo: DE0-CV board top for the G3 physical UART echo.
// 115200 8N1 (CLK 50 MHz, REF 3.6864 MHz, DIV 2), no CPU, no SDRAM.
// Design: fpga/de0-cv/UART_BOARD_ECHO_DESIGN.md.
//
//   LEDR0 heartbeat, LEDR1 RX activity, LEDR2 TX activity, LEDR3 FE seen,
//   LEDR4 BREAK seen, LEDR5 overflow seen, LEDR6..8 = 0, LEDR9 reset released.
//   KEY0 (active Low) resets everything (asynchronous assert, 2-FF release).
//
// Pins (JP1 = GPIO 0, DE0-CV User Manual Fig. 3-12 / Table 3-7):
//   UART_TXD = JP1-8  = GPIO_0_D7 = PIN_K22 (FPGA output)
//   UART_RXD = JP1-10 = GPIO_0_D9 = PIN_M21 (FPGA input, weak pull-up)
module de0_cv_uart_echo #(
    parameter int unsigned CLK_HZ          = 50_000_000,
    parameter int unsigned REF_HZ          = 3_686_400,
    parameter logic [15:0] DIVISOR         = 16'd2,
    parameter int unsigned HEARTBEAT_HALF  = 25_000_000,  // 0.5 s at 50 MHz
    parameter int unsigned ACTIVITY_CYCLES = 2_500_000    // 50 ms LED stretch
) (
    input  logic       CLOCK_50,
    input  logic       KEY0_N,
    input  logic       UART_RXD,
    output logic       UART_TXD,
    output logic [9:0] LEDR
);

    // ------------------------------------------------------------------
    // Reset: KEY0 asserts asynchronously, release through two flops
    // (same structure and names as the verified blink design).
    // ------------------------------------------------------------------
    (* async_reg = "true" *) logic reset_meta;
    (* async_reg = "true" *) logic reset_n;

    always_ff @(posedge CLOCK_50 or negedge KEY0_N) begin
        if (!KEY0_N) begin
            reset_meta <= 1'b0;
            reset_n    <= 1'b0;
        end else begin
            reset_meta <= 1'b1;
            reset_n    <= reset_meta;
        end
    end

    // ------------------------------------------------------------------
    // PHY + echo buffer
    // ------------------------------------------------------------------
    logic       tx_valid;
    logic [7:0] tx_data;
    logic       tx_ready;
    logic       tx_busy;
    logic       rx_valid;
    logic [7:0] rx_data;
    logic       rx_fe;
    logic       rx_bi;
    logic       rx_busy;
    logic       fe_seen;
    logic       bi_seen;
    logic       ovf_seen;

    // The 16-bit counters are simulation-visible outputs of the core only. They
    // are unused at the top, so synthesis removes them; on the board the sticky
    // LEDs (LEDR3/4/5) are the diagnostics.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] rx_ok_cnt;
    logic [15:0] fe_cnt;
    logic [15:0] bi_cnt;
    logic [15:0] ovf_cnt;
    logic [15:0] tx_cnt;
    /* verilator lint_on UNUSEDSIGNAL */

    uart_phy #(
        .CLK_HZ(CLK_HZ),
        .REF_HZ(REF_HZ)
    ) u_phy (
        .clk         (CLOCK_50),
        .rst_n       (reset_n),
        .divisor     (DIVISOR),
        .tx_valid    (tx_valid),
        .tx_data     (tx_data),
        .tx_ready    (tx_ready),
        .tx_busy     (tx_busy),
        .txd         (UART_TXD),
        .rxd         (UART_RXD),
        .rx_valid    (rx_valid),
        .rx_data     (rx_data),
        .rx_frame_err(rx_fe),
        .rx_break    (rx_bi),
        .rx_busy     (rx_busy)
    );

    uart_echo_core #(
        .DEPTH(16),
        .CNT_W(16)
    ) u_echo (
        .clk      (CLOCK_50),
        .rst_n    (reset_n),
        .rx_valid (rx_valid),
        .rx_data  (rx_data),
        .rx_fe    (rx_fe),
        .rx_bi    (rx_bi),
        .tx_valid (tx_valid),
        .tx_data  (tx_data),
        .tx_ready (tx_ready),
        .fe_seen  (fe_seen),
        .bi_seen  (bi_seen),
        .ovf_seen (ovf_seen),
        .rx_ok_cnt(rx_ok_cnt),
        .fe_cnt   (fe_cnt),
        .bi_cnt   (bi_cnt),
        .ovf_cnt  (ovf_cnt),
        .tx_cnt   (tx_cnt)
    );

    // ------------------------------------------------------------------
    // LED indicators
    // ------------------------------------------------------------------
    localparam int unsigned HB_W  = (HEARTBEAT_HALF > 1) ? $clog2(HEARTBEAT_HALF) : 1;
    localparam int unsigned ACT_W = (ACTIVITY_CYCLES > 1) ? $clog2(ACTIVITY_CYCLES + 1) : 1;

    logic [HB_W-1:0]  hb_count;
    logic             hb_led;
    logic [ACT_W-1:0] rx_act;
    logic [ACT_W-1:0] tx_act;
    logic             tx_fire;
    logic             rx_ok_event;

    // tx_busy/rx_busy are PHY status signals not needed for the LEDs.
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_busy;
    assign unused_busy = tx_busy ^ rx_busy;
    /* verilator lint_on UNUSEDSIGNAL */

    assign tx_fire     = tx_valid && tx_ready;
    assign rx_ok_event = rx_valid && !rx_fe && !rx_bi;

    always_ff @(posedge CLOCK_50 or negedge reset_n) begin
        if (!reset_n) begin
            hb_count <= '0;
            hb_led   <= 1'b0;
            rx_act   <= '0;
            tx_act   <= '0;
        end else begin
            if (hb_count == HB_W'(HEARTBEAT_HALF - 1)) begin
                hb_count <= '0;
                hb_led   <= !hb_led;
            end else begin
                hb_count <= hb_count + 1'b1;
            end

            if (rx_ok_event) begin
                rx_act <= ACT_W'(ACTIVITY_CYCLES);
            end else if (rx_act != '0) begin
                rx_act <= rx_act - 1'b1;
            end

            if (tx_fire) begin
                tx_act <= ACT_W'(ACTIVITY_CYCLES);
            end else if (tx_act != '0) begin
                tx_act <= tx_act - 1'b1;
            end
        end
    end

    assign LEDR[0] = hb_led;
    assign LEDR[1] = (rx_act != '0);
    assign LEDR[2] = (tx_act != '0);
    assign LEDR[3] = fe_seen;
    assign LEDR[4] = bi_seen;
    assign LEDR[5] = ovf_seen;
    assign LEDR[6] = 1'b0;
    assign LEDR[7] = 1'b0;
    assign LEDR[8] = 1'b0;
    assign LEDR[9] = reset_n;

endmodule : de0_cv_uart_echo
