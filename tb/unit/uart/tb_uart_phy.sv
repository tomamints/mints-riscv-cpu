`timescale 1ns/1ps
// tb_uart_phy: bit-level testbench for fpga/de0-cv/rtl/uart_{baud_gen,tx,rx,phy}.sv
//
// Reference models are independent of the RTL baud generator: expected times
// are computed only from Tbit = 16 * div / REF_HZ (real arithmetic), the TX is
// checked by a real-time serial decoder, and the RX is driven by a real-time
// host serial model with an arbitrary (non-clock-aligned) phase.
//
// Parameter CLK_HZ: run once with 50_000_000 and once with 20_000_000.
// Exit: $fatal(1, ...) on any failure (non-zero exit), "UART_PHY_TB_PASS" on success.
module tb_uart_phy #(
    parameter int unsigned CLK_HZ = 50_000_000
);

    localparam int unsigned REF_HZ          = 3_686_400;
    localparam real         TCLK            = 1.0e9 / real'(CLK_HZ);    // ns
    localparam real         EPS             = 0.002;                    // ns (2 ps)
    localparam real         WATCHDOG_NS     = 1.5e9;                    // 1.5 s simulated
    localparam int unsigned WAIT_LIMIT_CLKS = 4_000_000;

    function automatic real tbit_ns(input int unsigned div);
        return 16.0 * real'(div) * 1.0e9 / real'(REF_HZ);
    endfunction

    // ------------------------------------------------------------------
    // Clock, watchdog, helpers
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    always #(TCLK / 2.0) clk = ~clk;

    initial begin
        #(WATCHDOG_NS);
        $fatal(1, "[TB] WATCHDOG: simulation exceeded %0.0f ns", WATCHDOG_NS);
    end

    task automatic wait_until(input real t);
        if (t > $realtime) #(t - $realtime);
    endtask

    task automatic wait_clks(input int unsigned n);
        repeat (n) @(posedge clk);
    endtask

    task automatic host_phase_jitter();
        #(real'($urandom_range(0, 999)) * TCLK / 1000.0);
    endtask

    // ------------------------------------------------------------------
    // DUTs
    // ------------------------------------------------------------------
    // TX under test
    logic        tx_rst_n;
    logic [15:0] tx_div;
    logic        tx_valid;
    logic [7:0]  tx_data;
    logic        tx_ready;
    logic        txd;
    logic        tx_busy;

    uart_tx #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) u_tx (
        .clk(clk), .rst_n(tx_rst_n), .divisor(tx_div),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .txd(txd), .tx_busy(tx_busy)
    );

    // RX under test, driven by the host model
    logic        rx_rst_n;
    logic [15:0] rx_div;
    logic        host_line;
    logic        rx_valid;
    logic [7:0]  rx_data;
    logic        rx_fe;
    logic        rx_bi;
    logic        rx_busy;

    uart_rx #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) u_rx (
        .clk(clk), .rst_n(rx_rst_n), .divisor(rx_div), .rxd(host_line),
        .rx_valid(rx_valid), .rx_data(rx_data), .rx_frame_err(rx_fe),
        .rx_break(rx_bi), .rx_busy(rx_busy)
    );

    // PHY wrapper in TX->RX loopback
    logic        phy_rst_n;
    logic [15:0] phy_div;
    logic        phy_tx_valid;
    logic [7:0]  phy_tx_data;
    logic        phy_tx_ready;
    logic        phy_tx_busy;
    logic        phy_txd;
    logic        phy_rx_valid;
    logic [7:0]  phy_rx_data;
    logic        phy_rx_fe;
    logic        phy_rx_bi;
    logic        phy_rx_busy;

    uart_phy #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) u_phy (
        .clk(clk), .rst_n(phy_rst_n), .divisor(phy_div),
        .tx_valid(phy_tx_valid), .tx_data(phy_tx_data), .tx_ready(phy_tx_ready),
        .tx_busy(phy_tx_busy), .txd(phy_txd),
        .rxd(phy_txd),
        .rx_valid(phy_rx_valid), .rx_data(phy_rx_data), .rx_frame_err(phy_rx_fe),
        .rx_break(phy_rx_bi), .rx_busy(phy_rx_busy)
    );

    // Baud generator stand-alone
    logic        bg_rst_n;
    logic        bg_restart;
    logic [15:0] bg_div;
    logic        bg_tick16;
    logic [15:0] bg_div_q;

    uart_baud_gen #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) u_bg (
        .clk(clk), .rst_n(bg_rst_n), .restart(bg_restart), .divisor(bg_div),
        .tick16(bg_tick16), .divisor_latched(bg_div_q)
    );

    // ------------------------------------------------------------------
    // TX monitors / scoreboard / protocol checks
    // ------------------------------------------------------------------
    int unsigned tx_fall_cnt = 0;
    int unsigned tx_edge_cnt = 0;
    real         tx_last_fall = 0.0;
    real         tx_busy_fall_t = 0.0;
    bit          tx_cap_en = 1'b0;
    real         tx_cap_t[$];
    logic        tx_cap_v[$];
    real         tx_hs_t[$];
    logic [7:0]  tx_exp_q[$];
    logic [7:0]  tx_src_q[$];
    int unsigned tx_hs_cnt = 0;
    logic        tx_prev_fire = 1'b0;

    always @(negedge txd) begin
        tx_fall_cnt++;
        tx_last_fall = $realtime;
    end

    always @(txd) begin
        tx_edge_cnt++;
        if (tx_cap_en) begin
            tx_cap_t.push_back($realtime);
            tx_cap_v.push_back(txd);
        end
    end

    always @(negedge tx_busy) begin
        tx_busy_fall_t = $realtime;
    end

    always @(posedge clk) begin
        if (tx_rst_n) begin
            if (tx_ready && tx_busy)
                $fatal(1, "[TX] tx_ready while tx_busy at %0t", $realtime);
            if (tx_ready && tx_div == 16'd0)
                $fatal(1, "[TX] tx_ready with divisor 0 at %0t", $realtime);
            if (tx_prev_fire && tx_ready)
                $fatal(1, "[TX] tx_ready in the cycle after a transfer at %0t", $realtime);
            if (!tx_busy && txd !== 1'b1)
                $fatal(1, "[TX] txd not High while idle at %0t", $realtime);
            if (tx_valid && tx_ready) begin
                tx_exp_q.push_back(tx_data);
                tx_hs_t.push_back($realtime);
                tx_hs_cnt++;
            end
        end
        tx_prev_fire = tx_rst_n && tx_valid && tx_ready;
    end

    // ------------------------------------------------------------------
    // RX scoreboard: expected data/FE/BI and an absolute observation window
    // ------------------------------------------------------------------
    logic [7:0]  rx_exp_d[$];
    logic        rx_exp_fe[$];
    logic        rx_exp_bi[$];
    real         rx_exp_lo[$];
    real         rx_exp_hi[$];
    int unsigned rx_evt_cnt = 0;
    int unsigned rx_bi_cnt = 0;
    int unsigned rx_fe_cnt = 0;
    logic        rx_prev_valid = 1'b0;

    task automatic rx_expect(input logic [7:0] d, input logic fe, input logic bi,
                             input real lo, input real hi);
        rx_exp_d.push_back(d);
        rx_exp_fe.push_back(fe);
        rx_exp_bi.push_back(bi);
        rx_exp_lo.push_back(lo);
        rx_exp_hi.push_back(hi);
    endtask

    always @(posedge clk) begin
        if (rx_valid) begin
            logic [7:0] ed;
            logic       efe;
            logic       ebi;
            real        lo;
            real        hi;
            if (rx_exp_d.size() == 0)
                $fatal(1, "[RX] unexpected event data=%02x fe=%0b bi=%0b at %0t",
                       rx_data, rx_fe, rx_bi, $realtime);
            ed  = rx_exp_d.pop_front();
            efe = rx_exp_fe.pop_front();
            ebi = rx_exp_bi.pop_front();
            lo  = rx_exp_lo.pop_front();
            hi  = rx_exp_hi.pop_front();
            if (rx_data !== ed || rx_fe !== efe || rx_bi !== ebi)
                $fatal(1, "[RX] event mismatch got d=%02x fe=%0b bi=%0b exp d=%02x fe=%0b bi=%0b at %0t",
                       rx_data, rx_fe, rx_bi, ed, efe, ebi, $realtime);
            if ($realtime < lo || $realtime > hi)
                $fatal(1, "[RX] event time %0.3f outside [%0.3f, %0.3f] (d=%02x)",
                       $realtime, lo, hi, ed);
            rx_evt_cnt++;
            if (rx_bi) rx_bi_cnt++;
            if (rx_fe) rx_fe_cnt++;
        end
        if (rx_valid && rx_prev_valid)
            $fatal(1, "[RX] rx_valid High for two cycles at %0t", $realtime);
        if (rx_valid && rx_bi && !(rx_fe && rx_data == 8'h00))
            $fatal(1, "[RX] BI without FE/zero data at %0t", $realtime);
        rx_prev_valid = rx_valid;
    end

    task automatic rx_drain();
        int unsigned n;
        n = 0;
        while (rx_exp_d.size() != 0) begin
            @(posedge clk);
            n++;
            if (n > WAIT_LIMIT_CLKS)
                $fatal(1, "[RX] timeout waiting for %0d expected events", rx_exp_d.size());
        end
        wait_clks(4);
    endtask

    // ------------------------------------------------------------------
    // PHY loopback scoreboard
    // ------------------------------------------------------------------
    logic [7:0]  phy_exp_q[$];
    logic [7:0]  phy_src_q[$];
    int unsigned phy_evt_cnt = 0;

    always @(posedge clk) begin
        if (phy_rst_n && phy_tx_valid && phy_tx_ready)
            phy_exp_q.push_back(phy_tx_data);
        if (phy_rx_valid) begin
            logic [7:0] e;
            if (phy_exp_q.size() == 0)
                $fatal(1, "[LB] unexpected loopback event %02x at %0t", phy_rx_data, $realtime);
            e = phy_exp_q.pop_front();
            if (phy_rx_data !== e || phy_rx_fe !== 1'b0 || phy_rx_bi !== 1'b0)
                $fatal(1, "[LB] got d=%02x fe=%0b bi=%0b exp %02x", phy_rx_data, phy_rx_fe, phy_rx_bi, e);
            phy_evt_cnt++;
        end
    end

    // ------------------------------------------------------------------
    // TX master / decoder
    // ------------------------------------------------------------------
    // Protocol-compliant stream: valid held, next byte presented the cycle after
    // each transfer, valid dropped after the last one.
    task automatic tx_stream();
        int idx;
        int unsigned n;
        idx = 0;
        n = 0;
        if (tx_src_q.size() == 0) return;
        @(negedge clk);
        tx_valid = 1'b1;
        tx_data  = tx_src_q[0];
        while (idx < tx_src_q.size()) begin
            @(posedge clk);
            if (tx_valid && tx_ready) begin
                idx++;
                n = 0;
                @(negedge clk);
                if (idx < tx_src_q.size()) begin
                    tx_data = tx_src_q[idx];
                end else begin
                    tx_valid = 1'b0;
                    tx_data  = 8'h00;
                end
            end else begin
                n++;
                if (n > WAIT_LIMIT_CLKS) $fatal(1, "[TX] stream: no tx_ready");
            end
        end
    endtask

    // Independent decoder: waits for a start fall, samples at bit centres using
    // the nominal Tbit, checks stop High, edge count, and stop length >= 1 Tbit.
    task automatic tx_decode(input real tbit, output logic [7:0] d);
        int unsigned c0;
        int unsigned e0;
        int unsigned n;
        int unsigned exp_edges;
        int unsigned stop_falls;
        logic        prev;
        logic [9:0]  bits;
        real         t0;
        if (txd !== 1'b1) $fatal(1, "[TX-DEC] line not idle High at decoder entry (%0t)", $realtime);
        c0 = tx_fall_cnt;
        n  = 0;
        while (tx_fall_cnt == c0) begin
            @(posedge clk);
            n++;
            if (n > WAIT_LIMIT_CLKS) $fatal(1, "[TX-DEC] timeout waiting for start bit");
        end
        if (tx_fall_cnt != c0 + 1) $fatal(1, "[TX-DEC] more than one fall before start sample");
        t0 = tx_last_fall;
        e0 = tx_edge_cnt;
        for (int i = 0; i < 10; i++) begin
            wait_until(t0 + (real'(i) + 0.5) * tbit);
            bits[i] = txd;
        end
        if (bits[0] !== 1'b0) $fatal(1, "[TX-DEC] start bit not Low at centre (t0=%0.3f)", t0);
        if (bits[9] !== 1'b1) $fatal(1, "[TX-DEC] stop bit not High at centre (t0=%0.3f)", t0);
        d = bits[8:1];
        exp_edges = 0;
        prev = 1'b0;
        for (int i = 1; i < 10; i++) begin
            if (bits[i] != prev) exp_edges++;
            prev = bits[i];
        end
        if (tx_edge_cnt - e0 != exp_edges)
            $fatal(1, "[TX-DEC] %0d edges inside frame, expected %0d (glitch?)",
                   tx_edge_cnt - e0, exp_edges);
        // Stop length: no new fall from the stop-centre sample to t0 + 10 Tbit.
        stop_falls = tx_fall_cnt;
        wait_until(t0 + 10.0 * tbit - EPS);
        if (tx_fall_cnt != stop_falls || txd !== 1'b1)
            $fatal(1, "[TX-DEC] stop bit shorter than 1 Tbit (t0=%0.3f)", t0);
    endtask

    task automatic tx_run_and_check(input int unsigned div);
        int          n;
        int unsigned hs0;
        logic [7:0]  d;
        logic [7:0]  e;
        real         tb;
        n   = tx_src_q.size();
        hs0 = tx_hs_cnt;
        tb  = tbit_ns(div);
        fork
            tx_stream();
            begin
                for (int i = 0; i < n; i++) begin
                    tx_decode(tb, d);
                    if (tx_exp_q.size() == 0) $fatal(1, "[TX] decoded a frame without a transfer");
                    e = tx_exp_q.pop_front();
                    if (d !== e) $fatal(1, "[TX] decoded %02x expected %02x (frame %0d)", d, e, i);
                end
            end
        join
        if (tx_hs_cnt - hs0 != n) $fatal(1, "[TX] %0d transfers for %0d bytes", tx_hs_cnt - hs0, n);
        if (tx_exp_q.size() != 0) $fatal(1, "[TX] %0d transferred bytes not seen on txd", tx_exp_q.size());
    endtask

    // Check a captured 0x55 frame (every boundary toggles) starting at index base.
    task automatic tx_check_55(input int base, input real tbit, output real t0);
        real dev;
        real maxdev;
        real avg;
        if (tx_cap_t.size() < base + 10) $fatal(1, "[TX-TIM] only %0d edges captured", tx_cap_t.size());
        if (tx_cap_v[base] !== 1'b0) $fatal(1, "[TX-TIM] frame does not start with a fall");
        t0 = tx_cap_t[base];
        maxdev = 0.0;
        for (int k = 1; k <= 9; k++) begin
            if (tx_cap_v[base + k] !== ((k % 2) == 1))
                $fatal(1, "[TX-TIM] edge %0d has wrong polarity", k);
            dev = tx_cap_t[base + k] - (t0 + real'(k) * tbit);
            if (dev < -EPS || dev > TCLK + EPS)
                $fatal(1, "[TX-TIM] boundary %0d deviation %0.3f ns not in [0, %0.3f)", k, dev, TCLK);
            if (dev > maxdev) maxdev = dev;
        end
        avg = (tx_cap_t[base + 9] - t0) / 9.0;
        if (avg - tbit > TCLK / 9.0 + EPS || tbit - avg > EPS)
            $fatal(1, "[TX-TIM] average bit %0.3f ns vs ideal %0.3f ns", avg, tbit);
        $display("[TX-TIM] tbit=%0.3f ns avg=%0.3f ns baud=%0.2f max_dev=%0.3f ns",
                 tbit, avg, 1.0e9 / avg, maxdev);
    endtask

    task automatic tx_timing_test(input int unsigned div);
        real tb;
        real t0;
        real t1;
        real gap;
        real end_dev;
        tb = tbit_ns(div);
        @(negedge clk);
        tx_div = 16'(div);
        tx_cap_t.delete();
        tx_cap_v.delete();
        tx_hs_t.delete();
        tx_cap_en = 1'b1;
        tx_src_q = '{8'h55, 8'h55};
        tx_run_and_check(div);
        tx_cap_en = 1'b0;
        if (tx_cap_t.size() != 20) $fatal(1, "[TX-TIM] %0d edges for two 0x55 frames", tx_cap_t.size());
        tx_check_55(0, tb, t0);
        tx_check_55(10, tb, t1);
        if (t0 - tx_hs_t[0] > EPS || tx_hs_t[0] - t0 > EPS)
            $fatal(1, "[TX-TIM] start bit not on the transfer edge");
        gap = t1 - (t0 + 10.0 * tb);
        if (gap < TCLK - EPS || gap > 2.0 * TCLK + EPS)
            $fatal(1, "[TX-TIM] back-to-back gap %0.3f ns not in [Tclk, 2Tclk)", gap);
        wait_until(t1 + 10.0 * tb + 2.0 * TCLK);
        end_dev = tx_busy_fall_t - (t1 + 10.0 * tb);
        if (end_dev < -EPS || end_dev > TCLK + EPS)
            $fatal(1, "[TX-TIM] busy fall deviation %0.3f ns", end_dev);
    endtask

    task automatic wait_tx_busy();
        int unsigned n;
        n = 0;
        while (!tx_busy) begin
            @(posedge clk);
            n++;
            if (n > WAIT_LIMIT_CLKS) $fatal(1, "[TX] timeout waiting for busy");
        end
    endtask

    // ------------------------------------------------------------------
    // Host serial model (drives host_line in real time)
    // ------------------------------------------------------------------
    // Window for an event decided at the stop centre of a frame whose start fall
    // is at tf, for a receiver with bit time tbr.
    function automatic real win_stop_lo(input real tf, input real tbr);
        return tf + 9.5 * tbr + 3.0 * TCLK - EPS;
    endfunction
    function automatic real win_stop_hi(input real tf, input real tbr);
        return tf + 9.5 * tbr + 5.0 * TCLK + EPS;
    endfunction

    // One frame. Expectation for 0x00 with a Low stop is not modelled here
    // (use host_low); the line is left at stop_lvl.
    task automatic host_frame(input logic [7:0] d, input real tbh, input logic stop_lvl,
                              input real tbr, input bit expect_ev);
        real tf;
        tf = $realtime;
        if (expect_ev) begin
            if (!stop_lvl && d == 8'h00)
                $fatal(1, "[TB] host_frame: use host_low for 0x00 with Low stop");
            rx_expect(d, !stop_lvl, 1'b0, win_stop_lo(tf, tbr), win_stop_hi(tf, tbr));
        end
        host_line = 1'b0;
        #(tbh);
        for (int i = 0; i < 8; i++) begin
            host_line = d[i];
            #(tbh);
        end
        host_line = stop_lvl;
        #(tbh);
    endtask

    // Continuous Low of `dur` ns from an idle-High line, then High.
    // kind: 0 = no event, 1 = normal 0x00 (stop seen High), 2 = FE only
    // (High seen in BREAK-wait), 3 = BREAK (decided 10 Tbit after detect).
    task automatic host_low(input real dur, input real tbr, input int kind);
        real tf;
        tf = $realtime;
        unique case (kind)
            0: ;
            1: rx_expect(8'h00, 1'b0, 1'b0, win_stop_lo(tf, tbr), win_stop_hi(tf, tbr));
            2: rx_expect(8'h00, 1'b1, 1'b0, tf + dur + 3.0 * TCLK - EPS, tf + dur + 4.0 * TCLK + EPS);
            3: rx_expect(8'h00, 1'b1, 1'b1, tf + 10.0 * tbr + 3.0 * TCLK - EPS,
                         tf + 10.0 * tbr + 5.0 * TCLK + EPS);
            default: $fatal(1, "[TB] host_low: bad kind %0d", kind);
        endcase
        host_line = 1'b0;
        #(dur);
        host_line = 1'b1;
    endtask

    task automatic host_idle(input real dur);
        host_line = 1'b1;
        #(dur);
    endtask

    task automatic host_bytes_all(input int unsigned div, input real scale, input bit gaps);
        real tbr;
        real tbh;
        tbr = tbit_ns(div);
        tbh = tbr * scale;
        host_phase_jitter();
        for (int v = 0; v < 256; v++) begin
            if (gaps) begin
                host_idle(real'($urandom_range(0, 3)) * tbr);
                host_phase_jitter();
            end
            host_frame(8'(v), tbh, 1'b1, tbr, 1'b1);
        end
        host_idle(2.0 * tbr);
        rx_drain();
    endtask

    task automatic host_bytes_set(input int unsigned div, input real scale, input int unsigned n_random);
        real tbr;
        real tbh;
        logic [7:0] corner [8];
        corner = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h7F, 8'hFE};
        tbr = tbit_ns(div);
        tbh = tbr * scale;
        host_phase_jitter();
        for (int i = 0; i < 8; i++) host_frame(corner[i], tbh, 1'b1, tbr, 1'b1);
        for (int unsigned i = 0; i < n_random; i++) host_frame(8'($urandom), tbh, 1'b1, tbr, 1'b1);
        host_idle(2.0 * tbr);
        rx_drain();
    endtask

    task automatic rx_set_div(input logic [15:0] div);
        @(negedge clk);
        rx_div = div;
    endtask

    task automatic rx_check_quiet(input real dur);
        int unsigned c0;
        c0 = rx_evt_cnt;
        #(dur);
        if (rx_evt_cnt != c0) $fatal(1, "[RX] unexpected event during quiet window");
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic bg_check(input logic [15:0] div, input int unsigned nticks, input bit poke_div);
        int unsigned n;
        int unsigned i;
        real         ratio;
        real         ideal;
        real         dev;
        ratio = real'(CLK_HZ) / real'(REF_HZ);
        @(negedge clk);
        bg_div = div;
        bg_restart = 1'b1;
        @(negedge clk);
        bg_restart = 1'b0;
        if (bg_div_q !== div) $fatal(1, "[BG] divisor not latched on restart");
        n = 0;
        i = 0;
        while (i < nticks) begin
            @(posedge clk);
            n++;
            if (bg_tick16) begin
                i++;
                ideal = real'(i) * real'(div) * ratio;
                dev = real'(n) - ideal;
                if (dev < -1.0e-6 || dev >= 1.0 + 1.0e-6)
                    $fatal(1, "[BG] div=%0d tick %0d at clk %0d, ideal %0.4f", div, i, n, ideal);
                if (poke_div && i == 2) bg_div = ~div;   // must not change the latched rate
            end
            if (n > 32'd2_000_000 + 2 * 65536 * 16) $fatal(1, "[BG] div=%0d tick timeout", div);
        end
        $display("[BG] div=%0d %0d ticks OK (avg %0.4f clk/tick, ideal %0.4f)",
                 div, nticks, real'(n) / real'(nticks), real'(div) * ratio);
    endtask

    task automatic test_baud_gen();
        int unsigned n;
        bg_check(16'd1, 64, 1'b0);
        bg_check(16'd2, 64, 1'b0);
        bg_check(16'd27, 64, 1'b1);
        bg_check(16'd256, 8, 1'b0);
        bg_check(16'd65535, 2, 1'b0);
        bg_check(16'd2, 16, 1'b0);  // restart from an arbitrary phase
        // divisor 0: frozen
        @(negedge clk);
        bg_div = 16'd0;
        bg_restart = 1'b1;
        @(negedge clk);
        bg_restart = 1'b0;
        bg_div = 16'd1;   // without restart this must not enable ticks
        n = 0;
        repeat (5000) begin
            @(posedge clk);
            if (bg_tick16) n++;
        end
        if (n != 0) $fatal(1, "[BG] ticks with latched divisor 0");
        $display("[BG] PASS");
    endtask

    task automatic test_tx();
        real tb;
        int unsigned hs0;
        int unsigned f0;
        logic [7:0] d;
        logic [7:0] e;
        real t0;

        // T1: divisor 0 blocks transfers
        @(negedge clk);
        tx_div = 16'd0;
        tx_valid = 1'b1;
        tx_data = 8'h5A;
        hs0 = tx_hs_cnt;
        f0 = tx_fall_cnt;
        wait_until($realtime + 30.0 * tbit_ns(2));
        if (tx_hs_cnt != hs0 || tx_fall_cnt != f0 || txd !== 1'b1 || tx_ready !== 1'b0)
            $fatal(1, "[TX] activity with divisor 0");
        @(negedge clk);
        tx_valid = 1'b0;
        $display("[TX] div0 blocks transfers: PASS");

        // T2: basic patterns at DIV=2 (115200)
        @(negedge clk);
        tx_div = 16'd2;
        tx_src_q = '{8'h00, 8'hFF, 8'h55, 8'hAA, 8'h01, 8'h80, 8'h7F, 8'hFE};
        tx_run_and_check(2);
        $display("[TX] basic patterns DIV=2: PASS");

        // T3: timing, back-to-back gap, busy fall, for several divisors
        tx_timing_test(1);
        tx_timing_test(2);
        tx_timing_test(27);
        tx_timing_test(256);
        $display("[TX] timing DIV=1/2/27/256: PASS");

        // T4: back-to-back random stream
        @(negedge clk);
        tx_div = 16'd1;
        tx_src_q.delete();
        for (int i = 0; i < 32; i++) tx_src_q.push_back(8'($urandom));
        tx_run_and_check(1);
        $display("[TX] 32-byte back-to-back stream: PASS");

        // T5: valid/data toggling randomly; only transferred bytes may appear
        @(negedge clk);
        tx_div = 16'd1;
        tb = tbit_ns(1);
        hs0 = tx_hs_cnt;
        fork
            begin
                while (tx_hs_cnt - hs0 < 12) begin
                    @(negedge clk);
                    tx_valid = 1'($urandom_range(0, 1));
                    tx_data  = 8'($urandom);
                end
                tx_valid = 1'b0;
            end
            begin
                for (int i = 0; i < 12; i++) begin
                    tx_decode(tb, d);
                    if (tx_exp_q.size() == 0) $fatal(1, "[TX] noise: frame without transfer");
                    e = tx_exp_q.pop_front();
                    if (d !== e) $fatal(1, "[TX] noise: decoded %02x expected %02x", d, e);
                end
            end
        join
        if (tx_hs_cnt - hs0 != 12 || tx_exp_q.size() != 0) $fatal(1, "[TX] noise: transfer count");
        $display("[TX] random valid/data while busy: PASS");

        // T6a: divisor change mid-frame (2 -> 27) keeps the frame on the DIV=2 grid
        @(negedge clk);
        tx_div = 16'd2;
        tx_cap_t.delete();
        tx_cap_v.delete();
        tx_cap_en = 1'b1;
        tx_src_q = '{8'h55};
        fork
            tx_run_and_check(2);
            begin
                wait_tx_busy();
                #(4.3 * tbit_ns(2));
                @(negedge clk);
                tx_div = 16'd27;
            end
        join
        tx_cap_en = 1'b0;
        if (tx_cap_t.size() != 10) $fatal(1, "[TX] cfg-change frame: %0d edges", tx_cap_t.size());
        tx_check_55(0, tbit_ns(2), t0);
        // next frame uses the new divisor
        tx_cap_t.delete();
        tx_cap_v.delete();
        tx_cap_en = 1'b1;
        tx_src_q = '{8'h55};
        tx_run_and_check(27);
        tx_cap_en = 1'b0;
        tx_check_55(0, tbit_ns(27), t0);
        // T6b: divisor -> 0 mid-frame: frame completes, then no further transfer
        tx_src_q = '{8'hA5};
        fork
            tx_run_and_check(27);
            begin
                wait_tx_busy();
                #(3.0 * tbit_ns(27));
                @(negedge clk);
                tx_div = 16'd0;
            end
        join
        @(negedge clk);
        tx_valid = 1'b1;
        tx_data = 8'h3C;
        hs0 = tx_hs_cnt;
        f0 = tx_fall_cnt;
        wait_until($realtime + 20.0 * tbit_ns(27));
        if (tx_hs_cnt != hs0 || tx_fall_cnt != f0 || tx_ready !== 1'b0)
            $fatal(1, "[TX] transfer after divisor set to 0");
        @(negedge clk);
        tx_valid = 1'b0;
        $display("[TX] divisor change mid-frame (2->27, 27->0): PASS");

        // T7: reset aborts a frame; nothing residual is sent afterwards
        @(negedge clk);
        tx_div = 16'd2;
        tx_src_q = '{8'h00};
        fork
            tx_stream();
        join
        wait_tx_busy();
        #(3.0 * tbit_ns(2));
        @(posedge clk);
        #(0.3 * TCLK);
        tx_rst_n = 1'b0;
        #(0.001);
        if (txd !== 1'b1 || tx_busy !== 1'b0 || tx_ready !== 1'b0)
            $fatal(1, "[TX] reset did not force idle (txd=%0b busy=%0b ready=%0b)", txd, tx_busy, tx_ready);
        wait_clks(5);
        @(negedge clk);
        tx_rst_n = 1'b1;
        tx_exp_q.delete();
        f0 = tx_fall_cnt;
        wait_until($realtime + 12.0 * tbit_ns(2));
        if (tx_fall_cnt != f0 || txd !== 1'b1) $fatal(1, "[TX] residual transmission after reset");
        tx_src_q = '{8'hA5};
        tx_run_and_check(2);
        $display("[TX] reset abort: PASS");
        $display("[TX] PASS");
    endtask

    task automatic test_rx();
        real tb2;
        real tb1;
        tb2 = tbit_ns(2);
        tb1 = tbit_ns(1);

        // R0: line idle, DIV=2
        rx_set_div(16'd2);
        host_idle(3.0 * tb2);

        // R1: all 256 values back-to-back, then with random gaps and phase
        host_bytes_all(2, 1.0, 1'b0);
        host_bytes_all(2, 1.0, 1'b1);
        $display("[RX] DIV=2 all 256 (back-to-back and gapped): PASS");

        // R2: +/-3 %% baud difference
        host_bytes_all(2, 1.03, 1'b0);
        host_bytes_all(2, 0.97, 1'b0);
        $display("[RX] DIV=2 all 256 at +3%% and -3%%: PASS");

        // R3: DIV=1 and DIV=27
        rx_set_div(16'd1);
        host_idle(2.0 * tb1);
        host_bytes_all(1, 1.0, 1'b0);
        host_bytes_set(1, 1.03, 24);
        host_bytes_set(1, 0.97, 24);
        rx_set_div(16'd27);
        host_idle(2.0 * tbit_ns(27));
        host_bytes_set(27, 1.0, 24);
        host_bytes_set(27, 1.03, 4);
        host_bytes_set(27, 0.97, 4);
        $display("[RX] DIV=1 / DIV=27 incl. +/-3%%: PASS");

        // R4: glitches (no event), then a normal frame
        rx_set_div(16'd2);
        host_idle(2.0 * tb2);
        host_low(0.4 * tb2, tb2, 0);
        host_idle(2.0 * tb2);
        host_low(1.0 * TCLK, tb2, 0);
        host_idle(2.0 * tb2);
        host_low(0.37 * TCLK, tb2, 0);
        host_idle(2.0 * tb2);
        host_frame(8'hC3, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] glitch rejection: PASS");

        // R5: framing error with High data bits (decided at stop centre)
        host_frame(8'hA5, tb2, 1'b0, tb2, 1'b1);
        host_idle(2.0 * tb2);
        host_frame(8'h5A, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] framing error: PASS");

        // R6: BREAK threshold (>= 10 Tbit continuous Low)
        host_low(9.3 * tb2, tb2, 1);                 // stop centre High: normal 0x00
        host_idle(2.0 * tb2);
        host_low(9.7 * tb2, tb2, 2);                 // Low stop, High before 10 Tbit: FE only
        host_idle(2.0 * tb2);
        host_frame(8'h5A, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        host_low(10.0 * tb2 - 2.0 * TCLK, tb2, 2);   // just below the boundary: FE only
        host_idle(2.0 * tb2);
        host_frame(8'h3C, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        host_low(10.0 * tb2 + 3.0 * TCLK, tb2, 3);   // just above the boundary: BREAK
        host_idle(2.0 * tb2);
        host_frame(8'hC6, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        host_low(25.0 * tb2, tb2, 3);                // long hold: exactly one BREAK event
        host_idle(2.0 * tb2);
        host_frame(8'h81, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] BREAK below/at/above 10 Tbit and long hold: PASS");

        // R7: FE then the line held Low: one event, re-arm only after High
        host_frame(8'hF0, tb2, 1'b0, tb2, 1'b1);
        host_line = 1'b0;
        rx_check_quiet(30.0 * tb2);
        host_idle(2.0 * tb2);
        host_frame(8'h0F, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] held-Low re-arm: PASS");

        // R8: divisor change mid-frame (2 -> 1) keeps the latched DIV=2
        fork
            host_frame(8'h96, tb2, 1'b1, tb2, 1'b1);
            begin
                #(3.3 * tb2);
                rx_set_div(16'd1);
            end
        join
        host_idle(2.0 * tb1);
        host_frame(8'h69, tb1, 1'b1, tb1, 1'b1);
        host_idle(2.0 * tb1);
        // divisor -> 0 mid-frame: frame completes, frames while disabled are ignored
        fork
            host_frame(8'h3C, tb1, 1'b1, tb1, 1'b1);
            begin
                #(4.1 * tb1);
                rx_set_div(16'd0);
            end
        join
        host_idle(2.0 * tb1);
        host_frame(8'hEE, tb1, 1'b1, tb1, 1'b0);
        host_idle(3.0 * tb1);
        if (rx_busy !== 1'b0) $fatal(1, "[RX] busy while divisor 0");
        rx_set_div(16'd2);
        host_idle(1.0 * tb2);
        host_frame(8'h77, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] divisor change mid-frame (2->1, 1->0): PASS");

        // R9: enabling during a Low must not accept that Low as a start
        // (a) disabled, idle High, then Low; enable while Low; hold Low
        rx_set_div(16'd0);
        host_idle(3.0 * tb2);
        host_line = 1'b0;
        #(1.3 * tb2);
        rx_set_div(16'd2);
        rx_check_quiet(20.0 * tb2);
        host_idle(2.0 * tb2);
        host_frame(8'h96, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        // (b) disabled, enable in the middle of a frame (during Low data bit d0
        //     of 0xF0); later High bits re-arm; the next back-to-back frame is valid
        rx_set_div(16'd0);
        host_idle(3.0 * tb2);
        fork
            host_frame(8'hF0, tb2, 1'b1, tb2, 1'b0);
            begin
                #(1.5 * tb2);
                rx_set_div(16'd2);
            end
        join
        host_frame(8'h5A, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] enable during Low (held / mid-frame) and next frame: PASS");

        // R10: reset mid-frame (no event), reset while Low (no event)
        fork
            host_frame(8'h55, tb2, 1'b1, tb2, 1'b0);
            begin
                #(4.2 * tb2);
                @(negedge clk);
                rx_rst_n = 1'b0;
            end
        join
        if (rx_busy !== 1'b0 || rx_valid !== 1'b0) $fatal(1, "[RX] reset did not clear state");
        #(0.5 * tb2);
        @(negedge clk);
        rx_rst_n = 1'b1;
        host_idle(2.0 * tb2);
        host_frame(8'hA3, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        host_line = 1'b0;
        #(2.0 * tb2);
        @(negedge clk);
        rx_rst_n = 1'b0;
        wait_clks(5);
        @(negedge clk);
        rx_rst_n = 1'b1;
        rx_check_quiet(20.0 * tb2);
        host_idle(2.0 * tb2);
        host_frame(8'h3A, tb2, 1'b1, tb2, 1'b1);
        host_idle(2.0 * tb2);
        rx_drain();
        $display("[RX] reset during frame / during Low: PASS");
        $display("[RX] PASS");
    endtask

    task automatic phy_stream();
        int idx;
        int unsigned n;
        idx = 0;
        n = 0;
        @(negedge clk);
        phy_tx_valid = 1'b1;
        phy_tx_data  = phy_src_q[0];
        while (idx < phy_src_q.size()) begin
            @(posedge clk);
            if (phy_tx_valid && phy_tx_ready) begin
                idx++;
                n = 0;
                @(negedge clk);
                if (idx < phy_src_q.size()) begin
                    phy_tx_data = phy_src_q[idx];
                end else begin
                    phy_tx_valid = 1'b0;
                    phy_tx_data  = 8'h00;
                end
            end else begin
                n++;
                if (n > WAIT_LIMIT_CLKS) $fatal(1, "[LB] no tx_ready");
            end
        end
    endtask

    task automatic test_loopback(input int unsigned div);
        int unsigned c0;
        int unsigned n;
        @(negedge clk);
        phy_div = 16'(div);
        wait_clks(4);
        phy_src_q.delete();
        for (int v = 0; v < 256; v++) phy_src_q.push_back(8'(v));
        c0 = phy_evt_cnt;
        phy_stream();
        n = 0;
        while (phy_evt_cnt - c0 < 256) begin
            @(posedge clk);
            n++;
            if (n > WAIT_LIMIT_CLKS) $fatal(1, "[LB] timeout: %0d of 256", phy_evt_cnt - c0);
        end
        if (phy_exp_q.size() != 0) $fatal(1, "[LB] leftover expected bytes");
        $display("[LB] DIV=%0d all 256 values: PASS", div);
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    initial begin
        tx_rst_n = 1'b0;
        rx_rst_n = 1'b0;
        phy_rst_n = 1'b0;
        bg_rst_n = 1'b0;
        tx_div = 16'd0;
        tx_valid = 1'b0;
        tx_data = 8'h00;
        rx_div = 16'd0;
        host_line = 1'b1;
        phy_div = 16'd0;
        phy_tx_valid = 1'b0;
        phy_tx_data = 8'h00;
        bg_restart = 1'b0;
        bg_div = 16'd0;
        $display("[TB] tb_uart_phy CLK_HZ=%0d REF_HZ=%0d Tclk=%0.3f ns", CLK_HZ, REF_HZ, TCLK);
        wait_clks(5);
        @(negedge clk);
        tx_rst_n = 1'b1;
        rx_rst_n = 1'b1;
        phy_rst_n = 1'b1;
        bg_rst_n = 1'b1;
        wait_clks(5);
        if (txd !== 1'b1 || tx_ready !== 1'b0 || rx_busy !== 1'b0)
            $fatal(1, "[TB] bad state after reset");

        test_baud_gen();
        test_tx();
        test_rx();
        test_loopback(2);
        test_loopback(1);

        $display("[TB] covered: baud_gen rate/latch/div0/restart; TX 8N1 decode, ready/valid,");
        $display("[TB]          boundary timing <1 clk (DIV 1/2/27/256), back-to-back gap, cfg change,");
        $display("[TB]          div0, reset abort; RX 256 values (DIV 2/1), +/-3%%, DIV 27, glitch, FE,");
        $display("[TB]          BREAK <10/~10/>10 Tbit, held-Low re-arm, enable during Low, cfg change,");
        $display("[TB]          reset; TX->RX loopback 256 values (DIV 2/1).");
        $display("[TB] not covered: FIFO/IRQ/16550 regs, divisor 65535 frames, parameter-error elaboration,");
        $display("[TB]          synthesis/STA, board I/O.");
        $display("[TB] RX events=%0d (FE=%0d BI=%0d) LB events=%0d TX transfers=%0d",
                 rx_evt_cnt, rx_fe_cnt, rx_bi_cnt, phy_evt_cnt, tx_hs_cnt);
        $display("UART_PHY_TB_PASS clk_hz=%0d", CLK_HZ);
        $finish;
    end

endmodule : tb_uart_phy
