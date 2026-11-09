`timescale 1ns/1ps
// tb_de0_cv_uart_echo: board-top simulation of fpga/de0-cv/uart_echo/rtl/de0_cv_uart_echo.sv
// at CLK 50 MHz, REF 3.6864 MHz, DIV 2 (115200 8N1).
//
// Independent host model: a real-time serial driver into UART_RXD and a
// real-time serial decoder on UART_TXD; bit times come from Tbit = 32/REF_HZ.
// Stimulus/checks at negedge or in real time; posedge processes only count.
//
// Scope: short streams only. The +/-2 % cases check reception accuracy and
// echo of a short stream; unlimited loss-free continuous echo is NOT claimed
// (a faster host slowly accumulates bytes in the 16-entry buffer).
// Success marker: DE0_CV_UART_ECHO_TB_PASS.
module tb_de0_cv_uart_echo;

    localparam int unsigned CLK_HZ = 50_000_000;
    localparam int unsigned REF_HZ = 3_686_400;
    localparam real TCLK = 1.0e9 / real'(CLK_HZ);
    localparam real TBIT = 32.0 * 1.0e9 / real'(REF_HZ);   // DIV = 2
    localparam real EPS  = 0.002;
    localparam int unsigned HB_HALF = 1000;                  // shortened for simulation
    localparam int unsigned ACT_CYC = 2000;                  // 40 us > one frame

    logic clk = 1'b0;
    always #(TCLK / 2.0) clk = ~clk;
    logic key0_n = 1'b0;
    logic rxd = 1'b1;
    logic txd;
    logic [9:0] ledr;

    initial begin
        #(100_000_000.0);
        $fatal(1, "[TB] WATCHDOG");
    end

    de0_cv_uart_echo #(
        .CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ), .DIVISOR(16'd2),
        .HEARTBEAT_HALF(HB_HALF), .ACTIVITY_CYCLES(ACT_CYC)
    ) dut (
        .CLOCK_50(clk), .KEY0_N(key0_n), .UART_RXD(rxd), .UART_TXD(txd), .LEDR(ledr)
    );

    task automatic wait_until(input real t);
        if (t > $realtime) #(t - $realtime);
    endtask

    task automatic wait_until_negedge(input real t);
        wait_until(t);
        @(negedge clk);
    endtask

    // ------------------------------------------------------------------
    // Host serial decoder on UART_TXD (frame counter + edge/stop checks)
    // ------------------------------------------------------------------
    int unsigned txd_raw_fall_cnt = 0;   // all falls; stop-length check only
    int unsigned txd_edge_cnt = 0;       // all edges; in-frame glitch check
    int unsigned dec_start_cnt = 0;      // frames recognized by the decoder
    always @(negedge txd) txd_raw_fall_cnt++;
    always @(txd) txd_edge_cnt++;

    logic [7:0] dec_q[$];

    initial begin : tx_decoder
        real         t0;
        int unsigned e0;
        int unsigned f9;
        int unsigned exp_e;
        logic        prev;
        logic [9:0]  bits;
        forever begin
            @(negedge txd);
            #(EPS);
            if (!key0_n) continue;
            t0 = $realtime - EPS;
            dec_start_cnt++;
            e0 = txd_edge_cnt;
            for (int i = 0; i < 10; i++) begin
                wait_until(t0 + (real'(i) + 0.5) * TBIT);
                bits[i] = txd;
            end
            exp_e = 1;
            prev = 1'b0;
            for (int i = 1; i < 10; i++) begin
                if (bits[i] != prev) exp_e++;
                prev = bits[i];
            end
            if (bits[0] !== 1'b0) $fatal(1, "[DEC] start not Low at centre (t0=%0.0f)", t0);
            if (bits[9] !== 1'b1) $fatal(1, "[DEC] stop not High at centre (t0=%0.0f)", t0);
            if (txd_edge_cnt - e0 + 1 != exp_e) $fatal(1, "[DEC] glitch in frame (t0=%0.0f)", t0);
            dec_q.push_back(bits[8:1]);
            f9 = txd_raw_fall_cnt;
            wait_until(t0 + 10.0 * TBIT - EPS);
            if (txd_raw_fall_cnt != f9) $fatal(1, "[DEC] stop shorter than 1 Tbit (t0=%0.0f)", t0);
        end
    end

    // ------------------------------------------------------------------
    // Host serial driver into UART_RXD
    // ------------------------------------------------------------------
    task automatic host_frame(input logic [7:0] d, input real tb, input logic stop_lvl);
        #(0.37 * TCLK);
        rxd = 1'b0;
        #(tb);
        for (int i = 0; i < 8; i++) begin
            rxd = d[i];
            #(tb);
        end
        rxd = stop_lvl;
        #(tb);
    endtask

    task automatic host_idle(input real nbits);
        rxd = 1'b1;
        #(nbits * TBIT);
    endtask

    task automatic expect_echo(input logic [7:0] exp[$], input string what);
        real t_end;
        t_end = $realtime + (real'(exp.size()) + 3.0) * 10.5 * TBIT;
        while (dec_q.size() < exp.size()) begin
            @(negedge clk);
            if ($realtime > t_end) $fatal(1, "[%s] only %0d of %0d echoed", what, dec_q.size(), exp.size());
        end
        wait_until_negedge($realtime + 12.0 * TBIT);         // nothing extra may follow
        if (dec_q.size() != exp.size()) $fatal(1, "[%s] %0d extra bytes", what, dec_q.size() - exp.size());
        foreach (exp[i])
            if (dec_q[i] !== exp[i]) $fatal(1, "[%s] echo %0d = %02x expected %02x", what, i, dec_q[i], exp[i]);
        dec_q.delete();
    endtask

    task automatic key0_reset();
        @(negedge clk);
        key0_n = 1'b0;
        repeat (5) @(negedge clk);
        key0_n = 1'b1;
        repeat (5) @(negedge clk);
        dec_q.delete();
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    initial begin
        logic [7:0] exp[$];
        int unsigned n0;
        int unsigned hb_toggles;
        logic hb_prev;

        key0_reset();
        if (ledr[9] !== 1'b1) $fatal(1, "[RESET] LEDR9 not on after release");
        if (ledr[8:3] !== 6'b0 || txd !== 1'b1) $fatal(1, "[RESET] unexpected LED/TXD state");
        // heartbeat toggles every HB_HALF cycles
        hb_toggles = 0;
        hb_prev = ledr[0];
        repeat (4 * HB_HALF + 10) begin
            @(negedge clk);
            if (ledr[0] != hb_prev) hb_toggles++;
            hb_prev = ledr[0];
        end
        if (hb_toggles < 3 || hb_toggles > 5) $fatal(1, "[HB] %0d heartbeat toggles", hb_toggles);
        $display("[T] reset release, LEDR9, heartbeat: PASS");

        // Single byte, then all 256 values back-to-back at the nominal rate
        exp = '{8'h55};
        host_frame(8'h55, TBIT, 1'b1);
        host_idle(1.0);
        expect_echo(exp, "SINGLE");
        exp.delete();
        for (int v = 0; v < 256; v++) begin
            host_frame(8'(v), TBIT, 1'b1);
            exp.push_back(8'(v));
        end
        host_idle(1.0);
        expect_echo(exp, "ALL256");
        if (ledr[5] !== 1'b0) $fatal(1, "[ALL256] overflow at nominal rate");
        $display("[T] single byte and 256 values back-to-back echoed: PASS");

        // Short streams with +/-2 % host baud difference
        exp.delete();
        for (int i = 0; i < 64; i++) begin
            host_frame(8'(8'hA0 ^ i), TBIT * 0.98, 1'b1);   // host 2 % fast
            exp.push_back(8'(8'hA0 ^ i));
        end
        host_idle(1.0);
        expect_echo(exp, "FAST2");
        exp.delete();
        for (int i = 0; i < 64; i++) begin
            host_frame(8'(8'h3C + i), TBIT * 1.02, 1'b1);   // host 2 % slow
            exp.push_back(8'(8'h3C + i));
        end
        host_idle(1.0);
        expect_echo(exp, "SLOW2");
        if (ledr[3] || ledr[4] || ledr[5]) $fatal(1, "[PM2] diagnostic LED set by valid traffic");
        $display("[T] 64-byte streams at -2 %% / +2 %% host baud echoed: PASS");

        // Activity LEDs: stretched pulse after traffic, then off
        host_frame(8'h11, TBIT, 1'b1);                       // returns ~0.5 bit after the RX event
        @(negedge clk);
        if (ledr[1] !== 1'b1 || ledr[2] !== 1'b1) $fatal(1, "[ACT] LEDR1/2 not lit after RX/TX start");
        exp = '{8'h11};
        expect_echo(exp, "ACT");
        repeat (ACT_CYC + 5) @(negedge clk);
        if (ledr[1] !== 1'b0 || ledr[2] !== 1'b0) $fatal(1, "[ACT] activity LEDs did not turn off");
        $display("[T] RX/TX activity LEDs: PASS");

        // Framing error and BREAK: not echoed, flagged; normal byte still echoed
        n0 = dec_start_cnt;
        host_frame(8'hA5, TBIT, 1'b0);                       // Low stop
        host_idle(2.0);
        if (ledr[3] !== 1'b1 || ledr[4] !== 1'b0) $fatal(1, "[FE] LEDR3/4 = %b/%b", ledr[3], ledr[4]);
        rxd = 1'b0;                                          // BREAK, 25 bit times
        #(25.0 * TBIT);
        host_idle(2.0);
        if (ledr[4] !== 1'b1) $fatal(1, "[BI] LEDR4 not lit");
        if (dec_start_cnt != n0) $fatal(1, "[FE/BI] FE or BREAK byte was echoed");
        exp = '{8'h5A};
        host_frame(8'h5A, TBIT, 1'b1);
        host_idle(1.0);
        expect_echo(exp, "AFTER-ERR");
        if (ledr[5] !== 1'b0) $fatal(1, "[FE/BI] overflow LED set");
        $display("[T] FE / BREAK flagged and not echoed, later byte echoed: PASS");

        // KEY0 clears the sticky diagnostics
        key0_reset();
        if (ledr[3] || ledr[4] || ledr[5]) $fatal(1, "[KEY0] diagnostics not cleared");
        if (ledr[9] !== 1'b1) $fatal(1, "[KEY0] LEDR9 off after release");
        $display("[T] KEY0 reset clears diagnostics: PASS");

        $display("[TB] not covered: overflow at board level (core TB), long continuous streams, real board/host.");
        $display("DE0_CV_UART_ECHO_TB_PASS");
        $finish;
    end

endmodule : tb_de0_cv_uart_echo
