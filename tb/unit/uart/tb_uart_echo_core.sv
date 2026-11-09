`timescale 1ns/1ps
// tb_uart_echo_core: unit test of fpga/de0-cv/uart_echo/rtl/uart_echo_core.sv.
// Stimulus and checks at negedge; the posedge monitor only records TX bytes.
// Expected values come from a TB queue model, not from DUT internals.
// Instances: DEPTH=16/CNT_W=16 (main) and DEPTH=16/CNT_W=4 (counter saturation).
module tb_uart_echo_core;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    initial begin
        #(5_000_000);
        $fatal(1, "[TB] WATCHDOG");
    end

    // ------------------------------------------------------------------
    // DUTs
    // ------------------------------------------------------------------
    logic        rx_valid = 1'b0;
    logic [7:0]  rx_data = 8'h00;
    logic        rx_fe = 1'b0;
    logic        rx_bi = 1'b0;
    logic        tx_ready = 1'b0;
    logic        tx_valid;
    logic [7:0]  tx_data;
    logic        fe_seen, bi_seen, ovf_seen;
    logic [15:0] rx_ok_cnt, fe_cnt, bi_cnt, ovf_cnt, tx_cnt;

    uart_echo_core #(.DEPTH(16), .CNT_W(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_fe(rx_fe), .rx_bi(rx_bi),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .fe_seen(fe_seen), .bi_seen(bi_seen), .ovf_seen(ovf_seen),
        .rx_ok_cnt(rx_ok_cnt), .fe_cnt(fe_cnt), .bi_cnt(bi_cnt),
        .ovf_cnt(ovf_cnt), .tx_cnt(tx_cnt)
    );

    logic        s_tx_valid;
    logic [7:0]  s_tx_data;
    logic        s_fe_seen, s_bi_seen, s_ovf_seen;
    logic [3:0]  s_rx_ok_cnt, s_fe_cnt, s_bi_cnt, s_ovf_cnt, s_tx_cnt;

    uart_echo_core #(.DEPTH(16), .CNT_W(4)) dut_sat (
        .clk(clk), .rst_n(rst_n),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_fe(rx_fe), .rx_bi(rx_bi),
        .tx_valid(s_tx_valid), .tx_data(s_tx_data), .tx_ready(tx_ready),
        .fe_seen(s_fe_seen), .bi_seen(s_bi_seen), .ovf_seen(s_ovf_seen),
        .rx_ok_cnt(s_rx_ok_cnt), .fe_cnt(s_fe_cnt), .bi_cnt(s_bi_cnt),
        .ovf_cnt(s_ovf_cnt), .tx_cnt(s_tx_cnt)
    );

    // ------------------------------------------------------------------
    // Monitor (posedge: record only)
    // ------------------------------------------------------------------
    logic [7:0] got_q[$];
    always @(posedge clk) begin
        if (rst_n && tx_valid && tx_ready) got_q.push_back(tx_data);
    end

    // ------------------------------------------------------------------
    // Helpers (all return at a negedge)
    // ------------------------------------------------------------------
    task automatic do_reset();
        @(negedge clk);
        rst_n = 1'b0;
        rx_valid = 1'b0;
        rx_fe = 1'b0;
        rx_bi = 1'b0;
        tx_ready = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        got_q.delete();
    endtask

    // One RX event, optionally with tx_ready High in the same cycle.
    task automatic rx_event(input logic [7:0] d, input logic fe, input logic bi, input logic ready_same);
        rx_valid = 1'b1;
        rx_data  = d;
        rx_fe    = fe;
        rx_bi    = bi;
        tx_ready = ready_same;
        @(negedge clk);
        rx_valid = 1'b0;
        rx_fe    = 1'b0;
        rx_bi    = 1'b0;
        tx_ready = 1'b0;
        @(negedge clk);
    endtask

    task automatic drain(input int unsigned cycles);
        tx_ready = 1'b1;
        repeat (cycles) @(negedge clk);
        tx_ready = 1'b0;
        @(negedge clk);
    endtask

    task automatic expect_got(input logic [7:0] exp[$], input string what);
        if (got_q.size() != exp.size())
            $fatal(1, "[%s] got %0d bytes, expected %0d", what, got_q.size(), exp.size());
        foreach (exp[i])
            if (got_q[i] !== exp[i]) $fatal(1, "[%s] byte %0d = %02x expected %02x", what, i, got_q[i], exp[i]);
        got_q.delete();
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic t_fill_overflow();
        logic [7:0] exp[$];
        do_reset();
        for (int i = 0; i < 16; i++) begin
            rx_event(8'(8'h40 + i), 1'b0, 1'b0, 1'b0);
            exp.push_back(8'(8'h40 + i));
        end
        if (ovf_seen !== 1'b0 || ovf_cnt !== 16'd0) $fatal(1, "[FILL] overflow at 16 entries");
        if (tx_valid !== 1'b1) $fatal(1, "[FILL] tx_valid Low with data");
        rx_event(8'hEE, 1'b0, 1'b0, 1'b0);                // 17th with tx_ready = 0
        if (ovf_seen !== 1'b1 || ovf_cnt !== 16'd1) $fatal(1, "[FILL] 17th byte not reported as overflow");
        if (rx_ok_cnt !== 16'd17) $fatal(1, "[FILL] rx_ok_cnt %0d", rx_ok_cnt);
        drain(20);
        expect_got(exp, "FILL");                          // 0xEE was dropped
        if (tx_cnt !== 16'd16) $fatal(1, "[FILL] tx_cnt %0d", tx_cnt);
        $display("[T] 16 entries accepted, 17th with tx_ready=0 dropped + diagnosed: PASS");
    endtask

    task automatic t_full_push_pop();
        logic [7:0] exp[$];
        do_reset();
        for (int i = 0; i < 16; i++) begin
            rx_event(8'(8'h60 + i), 1'b0, 1'b0, 1'b0);
            exp.push_back(8'(8'h60 + i));
        end
        rx_event(8'h70, 1'b0, 1'b0, 1'b1);                // full + pop + push in one cycle
        exp.push_back(8'h70);
        if (ovf_seen !== 1'b0) $fatal(1, "[FULLPP] push with simultaneous pop was dropped");
        if (got_q.size() != 1) $fatal(1, "[FULLPP] expected one pop");
        drain(20);
        expect_got(exp, "FULLPP");
        // empty + push + (no data to pop): tx_ready High while empty does nothing
        rx_event(8'h71, 1'b0, 1'b0, 1'b1);
        drain(3);
        exp = '{8'h71};
        expect_got(exp, "EMPTY-PUSH");
        $display("[T] full buffer + simultaneous pop/push accepted, order kept: PASS");
    endtask

    task automatic t_fe_bi();
        logic [7:0] exp[$];
        do_reset();
        rx_event(8'hA5, 1'b1, 1'b0, 1'b0);                // FE
        rx_event(8'h00, 1'b1, 1'b1, 1'b0);                // BREAK (PHY reports FE+BI)
        rx_event(8'h5A, 1'b0, 1'b0, 1'b0);                // normal
        if (fe_seen !== 1'b1 || fe_cnt !== 16'd1) $fatal(1, "[FEBI] FE not counted once");
        if (bi_seen !== 1'b1 || bi_cnt !== 16'd1) $fatal(1, "[FEBI] BREAK not counted once");
        if (rx_ok_cnt !== 16'd1) $fatal(1, "[FEBI] rx_ok_cnt %0d", rx_ok_cnt);
        drain(5);
        exp = '{8'h5A};
        expect_got(exp, "FEBI");                          // FE/BREAK bytes not echoed
        do_reset();
        if (fe_seen || bi_seen || ovf_seen || fe_cnt != 0 || bi_cnt != 0 || rx_ok_cnt != 0 || tx_cnt != 0)
            $fatal(1, "[FEBI] reset did not clear diagnostics");
        $display("[T] FE/BREAK not echoed, counted, cleared by reset: PASS");
    endtask

    // All five counters are driven past 15 events; the CNT_W=4 instance must hold
    // at 15 while the CNT_W=16 instance shows the exact event count.
    task automatic t_saturation();
        do_reset();
        for (int i = 0; i < 20; i++) rx_event(8'(i), 1'b0, 1'b0, 1'b1);   // 20 valid, 19 pops (1 left)
        for (int i = 0; i < 20; i++) rx_event(8'h00, 1'b1, 1'b0, 1'b0);   // 20 FE
        for (int i = 0; i < 20; i++) rx_event(8'h00, 1'b1, 1'b1, 1'b0);   // 20 BREAK
        for (int i = 0; i < 15; i++) rx_event(8'(i), 1'b0, 1'b0, 1'b0);   // fill to 16 (tx_ready=0)
        for (int i = 0; i < 20; i++) rx_event(8'(i), 1'b0, 1'b0, 1'b0);   // 20 overflows
        if (s_rx_ok_cnt !== 4'hF || s_fe_cnt !== 4'hF || s_bi_cnt !== 4'hF ||
            s_ovf_cnt !== 4'hF || s_tx_cnt !== 4'hF)
            $fatal(1, "[SAT] CNT_W=4 not saturated: ok=%0d fe=%0d bi=%0d ovf=%0d tx=%0d",
                   s_rx_ok_cnt, s_fe_cnt, s_bi_cnt, s_ovf_cnt, s_tx_cnt);
        if (rx_ok_cnt !== 16'd55 || fe_cnt !== 16'd20 || bi_cnt !== 16'd20 ||
            ovf_cnt !== 16'd20 || tx_cnt !== 16'd19)
            $fatal(1, "[SAT] CNT_W=16 counts: ok=%0d fe=%0d bi=%0d ovf=%0d tx=%0d",
                   rx_ok_cnt, fe_cnt, bi_cnt, ovf_cnt, tx_cnt);
        if (!s_bi_seen || !s_ovf_seen || !s_fe_seen) $fatal(1, "[SAT] sticky flags");
        $display("[T] all five counters saturate at CNT_W=4 and count exactly at CNT_W=16: PASS");
    endtask

    initial begin
        t_fill_overflow();
        t_full_push_pop();
        t_fe_bi();
        t_saturation();
        $display("UART_ECHO_CORE_TB_PASS");
        $finish;
    end

endmodule : tb_uart_echo_core
