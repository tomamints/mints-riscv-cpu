`timescale 1ns/1ps
// tb_uart16550_phy: bit-level integration test of rtl/peripheral/uart16550_regs.sv
// and uart_phy through the uart16550_serial physical backend.
//
// Independence: register accesses go through a Membus BFM; the serial side is
// checked by an external real-time TX decoder and driven by an external
// real-time RX driver. Bit times come from the divisor the TB itself programmed
// (Tbit = 16*div/REF_HZ), never from DUT internals.
//
// Timing rule: stimulus, queue inspection and checks happen at negedge (or in
// real time on the serial line); posedge processes only count.
//
// Parameter CLK_HZ: run once with 50_000_000 and once with 20_000_000.
// Success marker: UART16550_PHY_TB_PASS. Failures: $fatal (non-zero exit).
module tb_uart16550_phy #(
    parameter int unsigned CLK_HZ = 50_000_000
);
    localparam int unsigned REF_HZ = 3_686_400;
    localparam real TCLK = 1.0e9 / real'(CLK_HZ);
    localparam real EPS  = 0.002;

    localparam logic [7:0] RBR = 8'd0, THR = 8'd0, DLL = 8'd0;
    localparam logic [7:0] IER = 8'd1, DLM = 8'd1;
    localparam logic [7:0] IIR = 8'd2, FCR = 8'd2;
    localparam logic [7:0] LCR = 8'd3, MCR = 8'd4, LSR = 8'd5, SCR = 8'd7;

    function automatic real tbit_ns(input int unsigned div);
        return 16.0 * real'(div) * 1.0e9 / real'(REF_HZ);
    endfunction

    // ------------------------------------------------------------------
    // Clock / reset / watchdog
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    always #(TCLK / 2.0) clk = ~clk;
    logic rst = 1'b0;   // active-low, shared by regs (rst) and PHY (rst_n)

    initial begin
        #(200_000_000.0);
        $fatal(1, "[TB] WATCHDOG");
    end

    task automatic wait_until(input real t);
        if (t > $realtime) #(t - $realtime);
    endtask

    task automatic wait_cycles(input int unsigned n);
        repeat (n) @(posedge clk);
        @(negedge clk);
    endtask

    // Advance to the first negedge at or after absolute time t.
    task automatic wait_until_negedge(input real t);
        wait_until(t);
        @(negedge clk);
    endtask

    // ------------------------------------------------------------------
    // DUT: regs + PHY, connected directly
    // ------------------------------------------------------------------
    Membus bus();

    logic        irq;
    logic        diag_tx_overflow;
    logic        diag_rx_overrun;
    logic        txd;
    logic        host_line = 1'b1;   // serial line into the PHY RX

    uart16550_serial #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) dut (
        .clk(clk), .rst(rst), .membus(bus), .irq(irq),
        .txd(txd), .rxd(host_line),
        .diag_tx_overflow(diag_tx_overflow), .diag_rx_overrun(diag_rx_overrun)
    );

    // ------------------------------------------------------------------
    // Membus BFM (returns at a negedge)
    // ------------------------------------------------------------------
    int unsigned acc_cnt = 0;
    int unsigned rv_cnt = 0;
    always @(posedge clk) begin
        if (bus.valid && bus.ready) acc_cnt++;
        if (bus.rvalid) rv_cnt++;
    end

    task automatic bus_op(input bit wr, input logic [7:0] off, input logic [7:0] wd,
                          output logic [7:0] rdv);
        int unsigned a0;
        int unsigned r0;
        int unsigned n;
        logic [2:0]  r;
        logic [63:0] rdata;
        r  = off[2:0];
        a0 = acc_cnt;
        r0 = rv_cnt;
        @(negedge clk);
        bus.valid = 1'b1;
        bus.addr  = 64'(off);
        bus.wen   = wr;
        bus.wdata = 64'(wd) << (8 * r);
        bus.wmask = 8'h01 << r;
        n = 0;
        forever begin
            @(posedge clk);
            n++;
            if (bus.valid && bus.ready) break;
            if (n > 50) $fatal(1, "[BFM] no ready");
        end
        @(negedge clk);
        bus.valid = 1'b0;
        @(posedge clk);
        if (bus.rvalid !== 1'b1) $fatal(1, "[BFM] no rvalid");
        rdata = bus.rdata;
        @(posedge clk);
        @(negedge clk);
        if (acc_cnt - a0 != 1 || rv_cnt - r0 != 1) $fatal(1, "[BFM] accept/rvalid count");
        rdv = rdata[8 * r +: 8];
    endtask

    task automatic wr8(input logic [7:0] off, input logic [7:0] d);
        logic [7:0] dummy;
        bus_op(1'b1, off, d, dummy);
    endtask

    task automatic rd8(input logic [7:0] off, output logic [7:0] v);
        bus_op(1'b0, off, 8'h00, v);
    endtask

    task automatic expect_rd(input logic [7:0] off, input logic [7:0] exp, input string what);
        logic [7:0] v;
        rd8(off, v);
        if (v !== exp) $fatal(1, "[%s] read off=%0d got %02x expected %02x (t=%0.0f)", what, off, v, exp, $realtime);
    endtask

    // ------------------------------------------------------------------
    // TB model of the programmed divisor (what the TB wrote, not DUT state)
    // ------------------------------------------------------------------
    int unsigned host_tx_div = 0;   // divisor the next TX frame must use
    int unsigned host_rx_div = 0;   // divisor for host -> PHY frames

    task automatic uart_init(input logic [15:0] div, input logic [7:0] fcr_value);
        wr8(LCR, 8'h80);
        wr8(DLL, div[7:0]);
        wr8(DLM, div[15:8]);
        host_tx_div = 32'(div);      // no new TX frame can start while DLAB=1
        host_rx_div = 32'(div);
        wr8(LCR, 8'h03);
        wr8(FCR, fcr_value);
        wr8(MCR, 8'h00);
    endtask

    // ------------------------------------------------------------------
    // External serial TX decoder (event driven on txd, real-time sampling)
    // ------------------------------------------------------------------
    // Raw line counters. txd_raw_fall_cnt counts EVERY falling edge (start bits and
    // falls inside data); it is used only inside the decoder for the stop-length
    // check (no fall between the stop-centre sample and t0+10*Tbit). It must not be
    // used to count frames. txd_edge_cnt counts all edges (in-frame glitch check).
    int unsigned txd_raw_fall_cnt = 0;
    int unsigned txd_edge_cnt = 0;
    always @(negedge txd) txd_raw_fall_cnt++;
    always @(txd) txd_edge_cnt++;

    // Frame counter: incremented when the decoder recognizes a start bit, i.e. a
    // fall seen while it is waiting for a frame (line idle). Falls inside a frame
    // being decoded are never counted here.
    //
    // No blind window: after a start the decoder is busy until t0+10*Tbit-EPS.
    //   * a fall before the stop-centre sample is part of the frame and is checked
    //     by the edge-count comparison (glitch => $fatal in strict mode);
    //   * a fall between the stop-centre sample and t0+10*Tbit-EPS is caught by the
    //     stop-length check ($fatal in strict mode);
    //   * from t0+10*Tbit-EPS the decoder waits on @(negedge txd) again; a correct
    //     next start comes no earlier than t0+10*Tbit+Tclk (PHY back-to-back gap).
    // During reset (rst=0) txd is forced High, so no start can be missed.
    int unsigned dec_start_cnt = 0;

    bit          dec_strict = 1'b1;   // cleared around intentional mid-frame resets
    logic [7:0]  dec_d[$];
    real         dec_t0[$];
    int unsigned dec_div[$];

    initial begin : tx_decoder
        real         t0;
        real         tb;
        int unsigned div;
        int unsigned e0;
        int unsigned f9;
        int unsigned exp_e;
        logic        prev;
        logic [9:0]  bits;
        forever begin
            @(negedge txd);
            // Let the edge counters (other processes, same time step) settle first.
            #(EPS);
            if (!rst) continue;
            t0  = $realtime - EPS;
            dec_start_cnt++;
            div = host_tx_div;
            if (div == 0) begin
                // Never expected: every test that sets divisor 0 runs in strict mode.
                // (In non-strict mode the frame length would be unknown.)
                $fatal(1, "[DEC] start bit while the programmed divisor is 0 (t=%0.0f)", t0);
            end
            tb = tbit_ns(div);
            e0 = txd_edge_cnt;
            for (int i = 0; i < 10; i++) begin
                wait_until(t0 + (real'(i) + 0.5) * tb);
                bits[i] = txd;
            end
            exp_e = 1;
            prev  = 1'b0;
            for (int i = 1; i < 10; i++) begin
                if (bits[i] != prev) exp_e++;
                prev = bits[i];
            end
            if (dec_strict) begin
                if (bits[0] !== 1'b0) $fatal(1, "[DEC] start not Low at centre (t0=%0.0f)", t0);
                if (bits[9] !== 1'b1) $fatal(1, "[DEC] stop not High at centre (t0=%0.0f)", t0);
                if (txd_edge_cnt - e0 + 1 != exp_e)
                    $fatal(1, "[DEC] %0d edges in frame, expected %0d (t0=%0.0f)", txd_edge_cnt - e0 + 1, exp_e, t0);
            end
            dec_d.push_back(bits[8:1]);
            dec_t0.push_back(t0);
            dec_div.push_back(div);
            f9 = txd_raw_fall_cnt;
            wait_until(t0 + 10.0 * tb - EPS);
            if (dec_strict && txd_raw_fall_cnt != f9) $fatal(1, "[DEC] stop shorter than 1 Tbit (t0=%0.0f)", t0);
        end
    end

    task automatic expect_frames(input logic [7:0] exp[$], input real timeout_ns, input string what);
        real t_end;
        t_end = $realtime + timeout_ns;
        while (dec_d.size() < exp.size()) begin
            @(negedge clk);
            if ($realtime > t_end) $fatal(1, "[%s] only %0d of %0d TX frames", what, dec_d.size(), exp.size());
        end
        foreach (exp[i])
            if (dec_d[i] !== exp[i]) $fatal(1, "[%s] TX frame %0d = %02x expected %02x", what, i, dec_d[i], exp[i]);
        if (dec_d.size() != exp.size()) $fatal(1, "[%s] %0d extra TX frames", what, dec_d.size() - exp.size());
    endtask

    task automatic dec_clear();
        dec_d.delete();
        dec_t0.delete();
        dec_div.delete();
    endtask

    // No NEW frame may start during dur_ns. A frame already in progress may
    // continue (its in-frame falls are not frame starts).
    task automatic expect_no_tx_start(input real dur_ns, input string what);
        int unsigned n0;
        n0 = dec_start_cnt;
        wait_until_negedge($realtime + dur_ns);
        if (dec_start_cnt != n0) $fatal(1, "[%s] %0d unexpected TX frame start(s)", what, dec_start_cnt - n0);
    endtask

    // Wait until at least n frames have started since the frame count n0
    // (sampled by the caller BEFORE the THR writes, so an early start is not missed).
    task automatic wait_tx_starts_since(input int unsigned n0, input int unsigned n, input real timeout_ns);
        real t_end;
        t_end = $realtime + timeout_ns;
        while (dec_start_cnt - n0 < n) begin
            @(negedge clk);
            if ($realtime > t_end) $fatal(1, "[TB] TX start timeout");
        end
    endtask

    // ------------------------------------------------------------------
    // External serial RX driver (real time, not aligned to clk)
    // ------------------------------------------------------------------
    task automatic host_frame(input logic [7:0] d, input logic stop_lvl);
        real tb;
        tb = tbit_ns(host_rx_div);
        #(0.37 * TCLK);              // arbitrary phase vs clk
        host_line = 1'b0;
        #(tb);
        for (int i = 0; i < 8; i++) begin
            host_line = d[i];
            #(tb);
        end
        host_line = stop_lvl;
        #(tb);
    endtask

    task automatic host_idle(input real nbits);
        host_line = 1'b1;
        #(nbits * tbit_ns(host_rx_div));
    endtask

    task automatic host_low(input real nbits);
        host_line = 1'b0;
        #(nbits * tbit_ns(host_rx_div));
        host_line = 1'b1;
    endtask

    // Wait until the PHY has finished receiving (rx side idle for a while).
    task automatic rx_settle();
        wait_cycles(8);
    endtask

    // ------------------------------------------------------------------
    // Reset
    // ------------------------------------------------------------------
    task automatic do_reset();
        @(negedge clk);
        rst = 1'b0;
        bus.valid = 1'b0;
        bus.wen   = 1'b0;
        bus.addr  = '0;
        bus.wdata = '0;
        bus.wmask = '0;
        host_line = 1'b1;
        host_tx_div = 0;
        host_rx_div = 0;
        wait_cycles(4);
        rst = 1'b1;
        wait_cycles(4);
        dec_clear();
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic t_basic();
        logic [7:0] exp[$];
        do_reset();
        uart_init(16'd2, 8'h01);
        expect_rd(LSR, 8'h60, "BASIC");
        expect_rd(IIR, 8'hC1, "BASIC");
        exp = '{8'h00, 8'hFF, 8'h55, 8'hA5, 8'h48};
        foreach (exp[i]) wr8(THR, exp[i]);
        expect_frames(exp, 7.0 * 10.5 * tbit_ns(2), "BASIC-TX");
        foreach (exp[i]) host_frame(exp[i], 1'b1);
        host_idle(1.0);
        rx_settle();
        foreach (exp[i]) expect_rd(RBR, exp[i], "BASIC-RX");
        expect_rd(LSR, 8'h60, "BASIC");
        if (diag_tx_overflow || diag_rx_overrun) $fatal(1, "[BASIC] diagnostics set");
        $display("[T] basic 115200 TX/RX (DIV=2): PASS");
    endtask

    task automatic t_tx_fifo16();
        logic [7:0] exp[$];
        real t_end;
        do_reset();
        uart_init(16'd2, 8'h01);
        wr8(IER, 8'h02);                         // ETBEI rise with empty FIFO
        if (irq !== 1'b1) $fatal(1, "[TX16] no THRE irq after enable");
        expect_rd(IIR, 8'hC2, "TX16");
        if (irq !== 1'b0) $fatal(1, "[TX16] irq not cleared by IIR read");
        for (int i = 0; i < 17; i++) begin       // 1 in the PHY + 16 in the FIFO
            exp.push_back(8'(8'h30 + i));
            wr8(THR, 8'(8'h30 + i));
        end
        if (diag_tx_overflow) $fatal(1, "[TX16] 17 writes with one frame in flight overflowed");
        expect_rd(LSR, 8'h00, "TX16");           // THRE=0, TEMT=0
        if (irq !== 1'b0) $fatal(1, "[TX16] irq while FIFO non-empty");
        t_end = $realtime + 20.0 * 10.5 * tbit_ns(2);
        while (irq !== 1'b1) begin               // last byte handed off -> THRE irq
            @(negedge clk);
            if ($realtime > t_end) $fatal(1, "[TX16] THRE irq timeout");
        end
        expect_rd(LSR, 8'h20, "TX16");           // THRE=1 while the last frame is on the line
        expect_rd(IIR, 8'hC2, "TX16");
        expect_frames(exp, 3.0 * 10.5 * tbit_ns(2), "TX16");
        // the decoder reports at the stop centre; TEMT rises at the stop end
        wait_until_negedge(dec_t0[dec_t0.size() - 1] + 10.0 * tbit_ns(2) + 4.0 * TCLK);
        expect_rd(LSR, 8'h60, "TX16");           // TEMT after the last stop bit
        $display("[T] TX FIFO 16 on the serial line: order, THRE/TEMT, THRE irq: PASS");
    endtask

    task automatic t_divisor_change();
        logic [7:0] exp[$];
        int unsigned f0;
        do_reset();
        uart_init(16'd2, 8'h01);
        f0 = dec_start_cnt;
        wr8(THR, 8'h55);                         // frame 0 at DIV=2
        wr8(THR, 8'h3C);                         // queued
        wait_tx_starts_since(f0, 1, 2.0 * tbit_ns(2));
        wait_until_negedge($realtime + 2.0 * tbit_ns(2));
        wr8(LCR, 8'h83);                         // DLAB: no new TX frame
        wr8(DLL, 8'h01);                         // divisor -> 1 while frame 0 is in flight
        host_tx_div = 1;                         // applies to frames started from now on
        host_rx_div = 1;
        expect_no_tx_start(10.0 * tbit_ns(2), "DIV-DLAB");   // frame 0 ends, 0x3C held back
        if (dec_d.size() != 1 || dec_div[0] != 2) $fatal(1, "[DIV] frame 0 not completed at DIV=2");
        wr8(LCR, 8'h03);
        exp = '{8'h55, 8'h3C};
        expect_frames(exp, 3.0 * 10.5 * tbit_ns(1), "DIV");
        if (dec_div[1] != 1) $fatal(1, "[DIV] frame 1 not at DIV=1");
        host_idle(2.0);
        host_frame(8'hC3, 1'b1);                 // RX at the new divisor (230400)
        host_idle(1.0);
        rx_settle();
        expect_rd(RBR, 8'hC3, "DIV-RX");
        $display("[T] divisor change: in-flight frame on old DIV, DLAB holds, new DIV after: PASS");
    endtask

    task automatic t_rx_overrun();
        do_reset();
        uart_init(16'd2, 8'h01);
        wr8(IER, 8'h05);                         // ERBFI | ELSI
        for (int i = 0; i < 17; i++) host_frame(8'(8'h60 + i), 1'b1);   // back-to-back
        host_idle(1.0);
        rx_settle();
        if (diag_rx_overrun !== 1'b1) $fatal(1, "[RX16] overrun not diagnosed");
        expect_rd(IIR, 8'hC6, "RX16");           // OE -> RLS
        expect_rd(LSR, 8'h63, "RX16");           // OE | DR (clears OE)
        expect_rd(IIR, 8'hC4, "RX16");
        for (int i = 0; i < 16; i++) expect_rd(RBR, 8'(8'h60 + i), "RX16");
        expect_rd(LSR, 8'h60, "RX16");
        expect_rd(IIR, 8'hC1, "RX16");
        $display("[T] RX 16 back-to-back + overrun, RBR drain, OE clear: PASS");
    endtask

    task automatic t_fe_bi_priority();
        do_reset();
        uart_init(16'd2, 8'h01);
        wr8(IER, 8'h07);                         // THRE pending at once (empty)
        host_frame(8'hA5, 1'b0);                 // framing error
        host_idle(2.0);
        host_low(25.0);                          // BREAK
        host_idle(2.0);
        host_frame(8'h5A, 1'b1);
        host_idle(1.0);
        rx_settle();
        expect_rd(IIR, 8'hC6, "FEBI");           // head FE: RLS
        expect_rd(LSR, 8'hE9, "FEBI");           // FIFOE | FE | DR
        expect_rd(IIR, 8'hC4, "FEBI");
        expect_rd(RBR, 8'hA5, "FEBI");
        expect_rd(IIR, 8'hC6, "FEBI");           // head BREAK
        expect_rd(LSR, 8'hF9, "FEBI");           // FIFOE | BI | FE | DR
        expect_rd(IIR, 8'hC4, "FEBI");
        expect_rd(RBR, 8'h00, "FEBI");
        expect_rd(LSR, 8'h61, "FEBI");
        expect_rd(RBR, 8'h5A, "FEBI");
        expect_rd(IIR, 8'hC2, "FEBI");           // THRE last
        expect_rd(IIR, 8'hC1, "FEBI");
        $display("[T] FE/BI from the PHY, RLS > RDA > THRE: PASS");
    endtask

    task automatic t_fcr_clear();
        logic [7:0] exp[$];
        int unsigned f0;
        do_reset();
        uart_init(16'd2, 8'h01);
        f0 = dec_start_cnt;
        for (int i = 0; i < 5; i++) wr8(THR, 8'(8'h11 + i));
        wait_tx_starts_since(f0, 1, 2.0 * tbit_ns(2));
        wait_until_negedge($realtime + 3.0 * tbit_ns(2));
        wr8(FCR, 8'h05);                         // TX clear while frame 0 is in flight
        expect_rd(LSR, 8'h20, "FCR-TX");         // FIFO empty, frame still on the line
        exp = '{8'h11};
        expect_frames(exp, 10.0 * tbit_ns(2), "FCR-TX");
        expect_no_tx_start(15.0 * tbit_ns(2), "FCR-TX");    // unsent bytes discarded
        expect_rd(LSR, 8'h60, "FCR-TX");
        dec_clear();
        // RX clear, then a frame that is already being received when the clear happens
        for (int i = 0; i < 3; i++) host_frame(8'(8'h21 + i), 1'b1);
        host_idle(1.0);
        rx_settle();
        fork
            host_frame(8'h77, 1'b1);
            begin
                wait_until_negedge($realtime + 3.0 * tbit_ns(2));
                wr8(FCR, 8'h03);
            end
        join
        host_idle(1.0);
        rx_settle();
        expect_rd(LSR, 8'h61, "FCR-RX");
        expect_rd(RBR, 8'h77, "FCR-RX");
        expect_rd(LSR, 8'h60, "FCR-RX");
        $display("[T] FCR TX clear keeps the in-flight frame, RX clear then receive: PASS");
    endtask

    task automatic t_reset();
        logic [7:0] exp[$];
        int unsigned f0;
        // (a) host sends while reset is held
        do_reset();
        @(negedge clk);
        rst = 1'b0;
        host_rx_div = 2;
        host_frame(8'h41, 1'b1);
        host_idle(1.0);
        @(negedge clk);
        rst = 1'b1;
        host_tx_div = 0;
        host_rx_div = 0;
        wait_cycles(4);
        expect_rd(LSR, 8'h60, "RST-HELD");
        expect_rd(IIR, 8'h01, "RST-HELD");
        uart_init(16'd2, 8'h01);
        host_frame(8'h42, 1'b1);
        host_idle(1.0);
        rx_settle();
        expect_rd(RBR, 8'h42, "RST-HELD");
        // (b) reset during a TX frame with bytes queued
        f0 = dec_start_cnt;
        for (int i = 0; i < 3; i++) wr8(THR, 8'(8'h81 + i));
        wait_tx_starts_since(f0, 1, 2.0 * tbit_ns(2));
        wait_until($realtime + 4.3 * tbit_ns(2));
        dec_strict = 1'b0;
        rst = 1'b0;                              // asynchronous, mid-frame
        #(0.001);
        if (txd !== 1'b1) $fatal(1, "[RST-TX] txd not idle High in reset");
        wait_cycles(5);
        rst = 1'b1;
        host_tx_div = 0;                         // reset clears DLL/DLM
        host_rx_div = 0;
        expect_no_tx_start(15.0 * tbit_ns(2), "RST-TX");    // queued bytes discarded
        dec_clear();
        dec_strict = 1'b1;
        expect_rd(LSR, 8'h60, "RST-TX");
        uart_init(16'd2, 8'h01);
        wr8(THR, 8'h99);
        exp = '{8'h99};
        expect_frames(exp, 12.0 * tbit_ns(2), "RST-TX");
        dec_clear();
        // (c) reset during an RX frame (released after the frame)
        fork
            host_frame(8'h5A, 1'b1);
            begin
                wait_until_negedge($realtime + 4.0 * tbit_ns(2));
                rst = 1'b0;
            end
        join
        host_idle(1.0);
        @(negedge clk);
        rst = 1'b1;
        host_tx_div = 0;
        host_rx_div = 0;
        wait_cycles(4);
        expect_rd(LSR, 8'h60, "RST-RX");
        uart_init(16'd2, 8'h01);
        host_frame(8'h5B, 1'b1);
        host_idle(1.0);
        rx_settle();
        expect_rd(RBR, 8'h5B, "RST-RX");
        expect_rd(LSR, 8'h60, "RST-RX");
        $display("[T] reset held / during TX / during RX discards old data: PASS");
    endtask

    task automatic t_divisor_zero();
        logic [7:0] exp[$];
        do_reset();
        uart_init(16'd2, 8'h01);
        wr8(LCR, 8'h80);
        wr8(DLL, 8'h00);
        wr8(DLM, 8'h00);
        host_tx_div = 0;                         // decoder: any start bit is an error
        wr8(LCR, 8'h03);
        wr8(THR, 8'h61);
        wr8(THR, 8'h62);
        expect_no_tx_start(20.0 * tbit_ns(2), "DIV0");
        expect_rd(LSR, 8'h00, "DIV0");           // data held, THRE=0, TEMT=0
        // The external host keeps sending at its normal rate (host_rx_div is still 2):
        // the PHY RX is disabled by divisor 0 and must ignore the frame.
        host_frame(8'h70, 1'b1);
        host_idle(2.0);
        rx_settle();
        expect_rd(LSR, 8'h00, "DIV0");
        wr8(LCR, 8'h80);
        wr8(DLL, 8'h02);
        host_tx_div = 2;
        wr8(LCR, 8'h03);
        exp = '{8'h61, 8'h62};
        expect_frames(exp, 3.0 * 10.5 * tbit_ns(2), "DIV0");
        host_idle(1.0);
        host_frame(8'h71, 1'b1);
        host_idle(1.0);
        rx_settle();
        expect_rd(RBR, 8'h71, "DIV0");
        wait_cycles(10);
        expect_rd(LSR, 8'h60, "DIV0");
        $display("[T] divisor 0 stops TX/RX, restore resumes: PASS");
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    initial begin
        bus.valid = 1'b0;
        bus.wen   = 1'b0;
        bus.addr  = '0;
        bus.wdata = '0;
        bus.wmask = '0;
        $display("[TB] tb_uart16550_phy CLK_HZ=%0d REF_HZ=%0d", CLK_HZ, REF_HZ);
        t_basic();
        t_tx_fifo16();
        t_divisor_change();
        t_rx_overrun();
        t_fe_bi_priority();
        t_fcr_clear();
        t_reset();
        t_divisor_zero();
        $display("[TB] not covered: sim backend/DPI, CPU/C tests/Linux, board I/O.");
        $display("UART16550_PHY_TB_PASS clk_hz=%0d", CLK_HZ);
        $finish;
    end

endmodule : tb_uart16550_phy
