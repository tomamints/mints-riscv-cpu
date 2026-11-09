`timescale 1ns/1ps
// tb_uart16550_regs: MMIO-level unit test for rtl/peripheral/uart16550_regs.sv.
//
// Independent checking: a bus functional model (BFM) for Membus, a TX sink
// queue and a simple PHY-busy model in the TB; expected register values are
// written out per test from the specification (fpga/de0-cv/UART_REGS_DESIGN.md),
// not computed from DUT internals. White-box probes are used only for counter
// range assertions.
//
// Profiles:
//   default                  : all functional tests, compiled WITHOUT MINTS_SIM.
//                              Dropped THR writes are checked via the sticky
//                              diag_tx_overflow output. Ends with UART16550_REGS_TB_PASS.
//   +define+MINTS_SIM +define+TB_SIM_ERROR_PROFILE
//                            : only the THR-overflow scenario; the RTL $error is
//                              EXPECTED to make the simulation exit non-zero.
//                              Reaching the end prints UART16550_REGS_SIM_ERROR_NOT_RAISED.
module tb_uart16550_regs;

    localparam logic [7:0] RBR = 8'd0, THR = 8'd0, DLL = 8'd0;
    localparam logic [7:0] IER = 8'd1, DLM = 8'd1;
    localparam logic [7:0] IIR = 8'd2, FCR = 8'd2;
    localparam logic [7:0] LCR = 8'd3, MCR = 8'd4, LSR = 8'd5, MSR = 8'd6, SCR = 8'd7;

    // ------------------------------------------------------------------
    // Clock / reset / watchdog
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst;

    initial begin
        #(20_000_000);
        $fatal(1, "[TB] WATCHDOG");
    end

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    Membus bus();

    logic        irq;
    logic [15:0] divisor;
    logic        tx_valid;
    logic [7:0]  tx_data;
    logic        tx_ready;
    logic        tx_busy;
    logic        rx_push;
    logic [7:0]  rx_data;
    logic        rx_fe;
    logic        rx_bi;
    logic        rx_space;
    logic        diag_tx_overflow;
    logic        diag_rx_overrun;

    uart16550_regs dut (
        .clk(clk), .rst(rst), .membus(bus), .irq(irq), .divisor(divisor),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy),
        .rx_push(rx_push), .rx_data(rx_data), .rx_fe(rx_fe), .rx_bi(rx_bi),
        .rx_space(rx_space),
        .diag_tx_overflow(diag_tx_overflow), .diag_rx_overrun(diag_rx_overrun)
    );

    // ------------------------------------------------------------------
    // TX sink + PHY busy model
    // ------------------------------------------------------------------
    logic        sink_ready = 1'b0;   // level set by tests
    logic        side_txr = 1'b0;     // one-cycle forced ready, driven only by the BFM at a negedge
    bit          side_txr_req = 1'b0; // set by a test before a *_side access
    bit          phy_model_en = 1'b0;
    int unsigned phy_cycles = 30;
    int unsigned phy_left = 0;
    logic        phy_busy = 1'b0;
    logic [7:0]  tx_got_q[$];
    bit          tb_dlab = 1'b0;

    assign tx_ready = (sink_ready && !(phy_model_en && phy_busy)) || side_txr;
    assign tx_busy  = phy_model_en && phy_busy;

    always @(posedge clk) begin
        if (rst) begin
            if (tx_valid && tb_dlab)
                $fatal(1, "[TB] tx_valid while DLAB=1 at %0t", $realtime);
            if (tx_valid && tx_ready) begin
                tx_got_q.push_back(tx_data);
                if (phy_model_en) begin
                    phy_busy <= 1'b1;
                    phy_left = phy_cycles;
                end
            end else if (phy_busy) begin
                if (phy_left <= 1) phy_busy <= 1'b0;
                else phy_left--;
            end
            // counter range (white-box)
            if (dut.tx_count > 5'd16 || dut.rx_count > 5'd16)
                $fatal(1, "[TB] FIFO count out of range tx=%0d rx=%0d", dut.tx_count, dut.rx_count);
            if (dut.rx_err_cnt > dut.rx_count)
                $fatal(1, "[TB] rx_err_cnt %0d > rx_count %0d", dut.rx_err_cnt, dut.rx_count);
            if (!dut.fcr0 && (dut.tx_count > 5'd1 || dut.rx_count > 5'd1))
                $fatal(1, "[TB] count above capacity 1 with FCR0=0");
            if (irq !== (dut.iir[3:0] != 4'h1))
                $fatal(1, "[TB] irq inconsistent with IIR");
            // THRE pending is only ever set by an empty event and cleared by THR writes,
            // so it implies an empty TX FIFO. (Hence an IIR read that REPORTS THRE cannot
            // coincide with a TX pop; the reachable race is tested in t_irq (g).)
            if (dut.thre_pending && dut.tx_count != 5'd0)
                $fatal(1, "[TB] thre_pending with non-empty TX FIFO");
            if (dut.thre_pending && !dut.ier[1])
                $fatal(1, "[TB] thre_pending with ETBEI=0");
        end
    end

    // ------------------------------------------------------------------
    // RX source
    // ------------------------------------------------------------------
    logic       side_rx = 1'b0;
    logic [7:0] side_rx_d = 8'h00;
    logic       side_rx_fe = 1'b0;
    logic       side_rx_bi = 1'b0;

    task automatic rx_inject(input logic [7:0] d, input logic fe = 1'b0, input logic bi = 1'b0);
        @(negedge clk);
        rx_push = 1'b1;
        rx_data = d;
        rx_fe   = fe;
        rx_bi   = bi;
        @(negedge clk);
        rx_push = 1'b0;
        rx_fe   = 1'b0;
        rx_bi   = 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Membus BFM
    // ------------------------------------------------------------------
    int unsigned acc_cnt = 0;
    int unsigned rv_cnt = 0;
    always @(posedge clk) begin
        if (bus.valid && bus.ready) acc_cnt++;
        if (bus.rvalid) rv_cnt++;
    end

    // One access. hold = extra cycles valid stays High after the accept.
    // with_side: apply side_* (rx push / forced tx_ready) in the accept cycle.
    task automatic bus_op(input bit wr, input logic [7:0] off, input logic [7:0] wd,
                          input bit lane_ok, input int unsigned hold, input bit with_side,
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
        bus.wmask = lane_ok ? (8'h01 << r) : (8'h01 << (3'(r + 3'd1)));
        if (with_side) begin
            rx_push  = side_rx;
            rx_data  = side_rx_d;
            rx_fe    = side_rx_fe;
            rx_bi    = side_rx_bi;
            side_txr = side_txr_req;
        end
        n = 0;
        forever begin
            @(posedge clk);
            n++;
            if (bus.valid && bus.ready) break;
            if (n > 50) $fatal(1, "[BFM] no ready");
        end
        if (with_side && n != 1) $fatal(1, "[BFM] side event not aligned with accept");
        @(negedge clk);
        // DLAB takes effect after the accept edge; track it from this negedge on.
        if (wr && lane_ok && r == LCR[2:0]) tb_dlab = wd[7];
        if (with_side) begin
            rx_push  = 1'b0;
            rx_fe    = 1'b0;
            rx_bi    = 1'b0;
            side_txr = 1'b0;
            side_txr_req = 1'b0;
            side_rx  = 1'b0;
        end
        if (hold == 0) bus.valid = 1'b0;
        @(posedge clk);
        if (bus.rvalid !== 1'b1) $fatal(1, "[BFM] no rvalid one cycle after accept");
        rdata = bus.rdata;
        for (int unsigned h = 1; h < hold; h++) @(negedge clk);
        if (hold != 0) begin
            @(negedge clk);
            bus.valid = 1'b0;
        end
        @(posedge clk);
        @(posedge clk);
        // Check and return at a negedge: the posedge monitors have finished, and
        // callers change stimulus / inspect queues outside the posedge Active region.
        @(negedge clk);
        if (acc_cnt - a0 != 1 || rv_cnt - r0 != 1)
            $fatal(1, "[BFM] off=%0d accepts=%0d rvalids=%0d (expected 1/1)", off, acc_cnt - a0, rv_cnt - r0);
        rdv = rdata[8 * r +: 8];
        if (!wr && ((rdata & ~(64'hff << (8 * r))) != 64'd0))
            $fatal(1, "[BFM] read data outside lane %0d: %016x", r, rdata);
    endtask

    // Wait n rising edges, then return at the following falling edge, so that
    // stimulus changes and queue inspection never race the posedge monitors.
    task automatic wait_cycles(input int unsigned n);
        repeat (n) @(posedge clk);
        @(negedge clk);
    endtask

    task automatic wr8(input logic [7:0] off, input logic [7:0] d);
        logic [7:0] dummy;
        bus_op(1'b1, off, d, 1'b1, 0, 1'b0, dummy);
    endtask

    task automatic wr8_side(input logic [7:0] off, input logic [7:0] d);
        logic [7:0] dummy;
        bus_op(1'b1, off, d, 1'b1, 0, 1'b1, dummy);
    endtask

    task automatic rd8(input logic [7:0] off, output logic [7:0] v);
        bus_op(1'b0, off, 8'h00, 1'b1, 0, 1'b0, v);
    endtask

    task automatic rd8_side(input logic [7:0] off, output logic [7:0] v);
        bus_op(1'b0, off, 8'h00, 1'b1, 0, 1'b1, v);
    endtask

    task automatic expect_rd(input logic [7:0] off, input logic [7:0] exp, input string what);
        logic [7:0] v;
        rd8(off, v);
        if (v !== exp) $fatal(1, "[%s] read off=%0d got %02x expected %02x", what, off, v, exp);
    endtask

    task automatic expect_rd_side(input logic [7:0] off, input logic [7:0] exp, input string what);
        logic [7:0] v;
        rd8_side(off, v);
        if (v !== exp) $fatal(1, "[%s] read off=%0d got %02x expected %02x", what, off, v, exp);
    endtask

    task automatic expect_tx(input logic [7:0] exp[$], input string what);
        if (tx_got_q.size() != exp.size())
            $fatal(1, "[%s] TX got %0d bytes, expected %0d", what, tx_got_q.size(), exp.size());
        foreach (exp[i])
            if (tx_got_q[i] !== exp[i])
                $fatal(1, "[%s] TX byte %0d got %02x expected %02x", what, i, tx_got_q[i], exp[i]);
        tx_got_q.delete();
    endtask

    task automatic do_reset();
        @(negedge clk);
        rst = 1'b0;
        bus.valid = 1'b0;
        bus.wen   = 1'b0;
        bus.addr  = '0;
        bus.wdata = '0;
        bus.wmask = '0;
        sink_ready = 1'b0;
        side_txr = 1'b0;
        side_txr_req = 1'b0;
        side_rx = 1'b0;
        rx_push = 1'b0;
        rx_data = 8'h00;
        rx_fe = 1'b0;
        rx_bi = 1'b0;
        phy_model_en = 1'b0;
        phy_busy = 1'b0;
        tb_dlab = 1'b0;
        repeat (3) @(negedge clk);
        rst = 1'b1;
        repeat (2) @(negedge clk);
        tx_got_q.delete();
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic t_reset_values();
        do_reset();
        expect_rd(IER, 8'h00, "RESET");
        expect_rd(IIR, 8'h01, "RESET");
        expect_rd(LCR, 8'h03, "RESET");
        expect_rd(MCR, 8'h00, "RESET");
        expect_rd(LSR, 8'h60, "RESET");
        expect_rd(MSR, 8'h00, "RESET");
        expect_rd(SCR, 8'h00, "RESET");
        expect_rd(RBR, 8'h00, "RESET");
        wr8(LCR, 8'h83);
        expect_rd(DLL, 8'h00, "RESET");
        expect_rd(DLM, 8'h00, "RESET");
        wr8(LCR, 8'h03);
        if (divisor !== 16'h0000 || irq !== 1'b0 || tx_valid !== 1'b0 || rx_space !== 1'b1
            || diag_tx_overflow !== 1'b0 || diag_rx_overrun !== 1'b0)
            $fatal(1, "[RESET] output values");
        $display("[T] reset values: PASS");
    endtask

    task automatic t_lanes_dlab();
        logic [7:0] dummy;
        do_reset();
        bus_op(1'b1, SCR, 8'hA5, 1'b0, 0, 1'b0, dummy);   // wrong lane: ignored
        expect_rd(SCR, 8'h00, "LANE");
        wr8(SCR, 8'hA5);
        expect_rd(SCR, 8'hA5, "LANE");
        expect_rd(8'h0F, 8'hA5, "LANE");                    // addr[7:3] ignored (alias)
        wr8(IER, 8'hFF);
        expect_rd(IER, 8'h0F, "LANE");
        wr8(IER, 8'h00);
        wr8(MCR, 8'hFF);
        expect_rd(MCR, 8'h1F, "LANE");
        wr8(MCR, 8'h00);
        wr8(LSR, 8'hFF);                                     // read-only: ignored
        expect_rd(LSR, 8'h60, "LANE");
        wr8(MSR, 8'hFF);
        expect_rd(MSR, 8'h00, "LANE");
        wr8(IER, 8'h05);
        wr8(LCR, 8'h83);
        wr8(DLL, 8'h34);
        wr8(DLM, 8'h12);
        expect_rd(DLL, 8'h34, "DLAB");
        expect_rd(DLM, 8'h12, "DLAB");
        expect_rd(LCR, 8'h83, "DLAB");
        if (divisor !== 16'h1234) $fatal(1, "[DLAB] divisor %04x", divisor);
        if (tx_valid !== 1'b0) $fatal(1, "[DLAB] DLL write entered TX FIFO");
        wr8(LCR, 8'h03);
        expect_rd(IER, 8'h05, "DLAB");
        expect_rd(LSR, 8'h60, "DLAB");
        $display("[T] lanes / mask / DLAB / alias: PASS");
    endtask

    task automatic t_held_valid();
        logic [7:0] v;
        logic [7:0] exp[$];
        do_reset();
        wr8(FCR, 8'h01);
        bus_op(1'b1, THR, 8'h58, 1'b1, 3, 1'b0, v);          // valid held 3 extra cycles
        sink_ready = 1'b1;
        wait_cycles(5);
        exp = '{8'h58};
        expect_tx(exp, "HELD");
        sink_ready = 1'b0;
        rx_inject(8'h61);
        rx_inject(8'h62);
        bus_op(1'b0, RBR, 8'h00, 1'b1, 3, 1'b0, v);
        if (v !== 8'h61) $fatal(1, "[HELD] RBR %02x", v);
        expect_rd(LSR, 8'h61, "HELD");                       // one byte left: single pop
        expect_rd(RBR, 8'h62, "HELD");
        expect_rd(LSR, 8'h60, "HELD");
        $display("[T] held valid: single accept / single side effect: PASS");
    endtask

    task automatic t_tx_fifo16();
        logic [7:0] exp[$];
        do_reset();
        wr8(FCR, 8'h01);
        for (int i = 0; i < 16; i++) wr8(THR, 8'(i));
        expect_rd(LSR, 8'h00, "TX16");                       // THRE=0, TEMT=0
        if (!tx_valid) $fatal(1, "[TX16] tx_valid Low with data");
        side_txr_req = 1'b1;                                 // full + pop in the same cycle
        wr8_side(THR, 8'h10);
        if (diag_tx_overflow !== 1'b0) $fatal(1, "[TX16] full+pop write was dropped");
        wr8(THR, 8'hEE);                                     // full, no pop: dropped
        if (diag_tx_overflow !== 1'b1) $fatal(1, "[TX16] overflow not diagnosed");
        sink_ready = 1'b1;
        wait_cycles(30);
        for (int i = 0; i <= 16; i++) exp.push_back(8'(i));
        expect_tx(exp, "TX16");
        expect_rd(LSR, 8'h60, "TX16");
        if (diag_tx_overflow !== 1'b1) $fatal(1, "[TX16] diag not sticky");
        // TEMT waits for the PHY frame
        phy_model_en = 1'b1;
        phy_cycles = 40;
        wr8(THR, 8'h77);
        expect_rd(LSR, 8'h20, "TX16-TEMT");                  // THRE=1 (handed off), TEMT=0
        wait_cycles(45);
        expect_rd(LSR, 8'h60, "TX16-TEMT");
        exp = '{8'h77};
        expect_tx(exp, "TX16-TEMT");
        $display("[T] TX FIFO 16: boundary, full+pop, overflow diag, THRE/TEMT: PASS");
    endtask

    task automatic t_cap1();
        logic [7:0] exp[$];
        do_reset();                                          // FCR0 = 0: capacity 1
        expect_rd(IIR, 8'h01, "CAP1");
        wr8(THR, 8'h43);
        side_txr_req = 1'b1;
        wr8_side(THR, 8'h44);                                // full(1) + pop: accepted
        if (diag_tx_overflow !== 1'b0) $fatal(1, "[CAP1] full+pop write dropped");
        wr8(THR, 8'h45);                                     // full(1), no pop: dropped
        if (diag_tx_overflow !== 1'b1) $fatal(1, "[CAP1] overflow not diagnosed");
        sink_ready = 1'b1;
        wait_cycles(5);
        exp = '{8'h43, 8'h44};
        expect_tx(exp, "CAP1");
        sink_ready = 1'b0;
        // RX capacity 1
        rx_inject(8'h58);
        expect_rd(LSR, 8'h61, "CAP1-RX");
        rx_inject(8'h59);                                    // second unread byte: overrun
        if (diag_rx_overrun !== 1'b1) $fatal(1, "[CAP1-RX] overrun diag");
        expect_rd(LSR, 8'h63, "CAP1-RX");                    // OE seen once (FIFOE=0 with FCR0=0)
        expect_rd(LSR, 8'h61, "CAP1-RX");
        expect_rd(RBR, 8'h58, "CAP1-RX");
        expect_rd(LSR, 8'h60, "CAP1-RX");
        // full(1) + RBR pop + push in one cycle: accepted, no OE
        rx_inject(8'h5A);
        side_rx = 1'b1;
        side_rx_d = 8'h57;
        expect_rd_side(RBR, 8'h5A, "CAP1-RX");
        expect_rd(LSR, 8'h61, "CAP1-RX");
        expect_rd(RBR, 8'h57, "CAP1-RX");
        $display("[T] FCR0=0 capacity 1 (TX/RX, full+pop, overflow, OE): PASS");
    endtask

    task automatic t_fcr_clear();
        logic [7:0] exp[$];
        do_reset();
        wr8(FCR, 8'h01);
        // (a) TX clear accepted while tx_ready is High: no handoff in that cycle
        wr8(THR, 8'h31);
        wr8(THR, 8'h32);
        wr8(THR, 8'h33);
        side_txr_req = 1'b1;
        wr8_side(FCR, 8'h05);
        sink_ready = 1'b1;
        wait_cycles(10);
        exp.delete();
        expect_tx(exp, "FCR-TXCLR");
        expect_rd(LSR, 8'h60, "FCR-TXCLR");
        // (b) TX clear does not stop a frame in progress (TEMT stays 0)
        phy_model_en = 1'b1;
        phy_cycles = 40;
        wr8(THR, 8'h34);
        wr8(FCR, 8'h05);
        expect_rd(LSR, 8'h20, "FCR-TXCLR-BUSY");
        wait_cycles(45);
        expect_rd(LSR, 8'h60, "FCR-TXCLR-BUSY");
        exp = '{8'h34};
        expect_tx(exp, "FCR-TXCLR-BUSY");
        phy_model_en = 1'b0;
        sink_ready = 1'b0;
        // (c) RX clear + push in the same cycle: the new byte remains
        rx_inject(8'h01);
        rx_inject(8'h02);
        rx_inject(8'h03);
        side_rx = 1'b1;
        side_rx_d = 8'h77;
        wr8_side(FCR, 8'h03);
        expect_rd(LSR, 8'h61, "FCR-RXCLR");
        expect_rd(RBR, 8'h77, "FCR-RXCLR");
        expect_rd(LSR, 8'h60, "FCR-RXCLR");
        // (d) FCR0 1->0 clears both FIFOs; IIR[7:6] follows FCR0
        rx_inject(8'h11);
        rx_inject(8'h12);
        wr8(THR, 8'h21);
        wr8(THR, 8'h22);
        expect_rd(IIR, 8'hC1, "FCR-TOGGLE");
        wr8(FCR, 8'h00);
        expect_rd(LSR, 8'h60, "FCR-TOGGLE");
        expect_rd(IIR, 8'h01, "FCR-TOGGLE");
        // (e) FCR0=0: clear bits ignored
        rx_inject(8'h13);
        wr8(FCR, 8'h02);
        expect_rd(LSR, 8'h61, "FCR-IGNORE");
        expect_rd(RBR, 8'h13, "FCR-IGNORE");
        // (f) FCR0 0->1 also clears
        rx_inject(8'h14);
        wr8(FCR, 8'h01);
        expect_rd(LSR, 8'h60, "FCR-TOGGLE01");
        sink_ready = 1'b1;
        wait_cycles(5);
        exp.delete();
        expect_tx(exp, "FCR-TOGGLE");
        $display("[T] FCR clear / toggle / ignore / clear+push / clear+tx_ready: PASS");
    endtask

    task automatic t_dlab_tx();
        logic [7:0] exp[$];
        do_reset();
        wr8(FCR, 8'h01);
        wr8(THR, 8'h41);
        wr8(THR, 8'h42);
        wr8(LCR, 8'h83);
        sink_ready = 1'b1;
        wait_cycles(10);                          // TB asserts tx_valid Low under DLAB
        exp.delete();
        expect_tx(exp, "DLAB-TX");
        wr8(DLL, 8'h02);                                     // goes to DLL, not the FIFO
        wr8(LCR, 8'h03);
        wait_cycles(5);
        exp = '{8'h41, 8'h42};
        expect_tx(exp, "DLAB-TX");
        if (divisor !== 16'h0002) $fatal(1, "[DLAB-TX] divisor %04x", divisor);
        $display("[T] DLAB suppresses TX handoff: PASS");
    endtask

    task automatic t_rx_fifo16();
        do_reset();
        wr8(FCR, 8'h01);
        for (int i = 0; i < 16; i++) rx_inject(8'(8'h10 + i));
        if (rx_space !== 1'b0) $fatal(1, "[RX16] rx_space with full FIFO");
        if (diag_rx_overrun !== 1'b0) $fatal(1, "[RX16] premature overrun");
        expect_rd(LSR, 8'h61, "RX16");
        rx_inject(8'hF0);                                    // 17th: overrun
        expect_rd(LSR, 8'h63, "RX16");
        expect_rd(LSR, 8'h61, "RX16");
        side_rx = 1'b1;                                      // full + pop + push
        side_rx_d = 8'hAB;
        expect_rd_side(RBR, 8'h10, "RX16");
        expect_rd(LSR, 8'h61, "RX16");
        for (int i = 1; i < 16; i++) expect_rd(RBR, 8'(8'h10 + i), "RX16");
        expect_rd(RBR, 8'hAB, "RX16");
        expect_rd(LSR, 8'h60, "RX16");
        if (rx_space !== 1'b1) $fatal(1, "[RX16] rx_space with empty FIFO");
        // LSR read and a new overrun in the same cycle: read returns old OE=0,
        // the new overrun wins over the clear.
        for (int i = 0; i < 16; i++) rx_inject(8'(i));
        side_rx = 1'b1;
        side_rx_d = 8'hCD;
        expect_rd_side(LSR, 8'h61, "RX16-RACE");
        expect_rd(LSR, 8'h63, "RX16-RACE");
        expect_rd(LSR, 8'h61, "RX16-RACE");
        wr8(FCR, 8'h03);
        expect_rd(LSR, 8'h60, "RX16-RACE");
        $display("[T] RX FIFO 16: boundary, OE sticky/clear, full+pop, LSR read vs overrun: PASS");
    endtask

    task automatic t_head_error();
        do_reset();
        wr8(FCR, 8'h01);
        wr8(IER, 8'h05);                                     // ERBFI | ELSI
        rx_inject(8'h41);
        rx_inject(8'h42, 1'b1, 1'b0);                         // FE
        rx_inject(8'h00, 1'b1, 1'b1);                         // BREAK (FE+BI)
        expect_rd(IIR, 8'hC4, "HEAD");                        // head ok: RDA
        expect_rd(LSR, 8'hE1, "HEAD");                        // FIFOE: 2 unacked errors
        expect_rd(RBR, 8'h41, "HEAD");
        expect_rd(IIR, 8'hC6, "HEAD");                        // head FE visible: RLS
        expect_rd(LSR, 8'hE9, "HEAD");                        // FE + FIFOE, acks head
        expect_rd(IIR, 8'hC4, "HEAD");
        expect_rd(LSR, 8'hE1, "HEAD");                        // FE hidden, 1 unacked (BREAK)
        expect_rd(RBR, 8'h42, "HEAD");
        expect_rd(LSR, 8'hF9, "HEAD");                        // BI+FE+FIFOE
        expect_rd(LSR, 8'h61, "HEAD");                        // acked, no unacked errors
        expect_rd(RBR, 8'h00, "HEAD");
        expect_rd(LSR, 8'h60, "HEAD");
        // LSR read while a new head (with error) arrives: new head is not acked
        side_rx = 1'b1;
        side_rx_d = 8'h55;
        side_rx_fe = 1'b1;
        expect_rd_side(LSR, 8'h60, "HEAD-RACE");             // old state returned
        side_rx_fe = 1'b0;
        expect_rd(LSR, 8'hE9, "HEAD-RACE");
        expect_rd(LSR, 8'h61, "HEAD-RACE");
        expect_rd(RBR, 8'h55, "HEAD-RACE");
        // FCR0 = 0: FIFOE always 0
        wr8(FCR, 8'h00);
        rx_inject(8'h66, 1'b1, 1'b0);
        expect_rd(LSR, 8'h69, "HEAD-CAP1");
        expect_rd(LSR, 8'h61, "HEAD-CAP1");
        expect_rd(RBR, 8'h66, "HEAD-CAP1");
        $display("[T] FE/BI per entry, head ack, LSR7, new head vs LSR read: PASS");
    endtask

    task automatic t_irq();
        do_reset();                                          // FCR0=0: IIR[7:6]=00
        // (a) Linux THRE re-assert probe: IER=THRI, IIR, IER=0, IER=THRI, IIR
        wr8(IER, 8'h02);
        if (irq !== 1'b1) $fatal(1, "[IRQ] no THRE irq after ETBEI rise");
        expect_rd(IIR, 8'h02, "IRQ-PROBE");
        expect_rd(IIR, 8'h01, "IRQ-PROBE");                  // cleared by the THRE read
        wr8(IER, 8'h00);
        wr8(IER, 8'h02);
        expect_rd(IIR, 8'h02, "IRQ-PROBE");
        wr8(IER, 8'h00);
        // (b) Linux TXEN test: IER=THRI, LSR (TEMT), IIR != NO_INT
        wr8(IER, 8'h02);
        expect_rd(LSR, 8'h60, "IRQ-TXEN");
        expect_rd(IIR, 8'h02, "IRQ-TXEN");
        // (c) IER rewritten 1->1 after the clear: no new event
        wr8(IER, 8'h02);
        expect_rd(IIR, 8'h01, "IRQ-REWRITE");
        // (d) ETBEI=0 forces pending 0; empty transition while disabled is not kept
        wr8(IER, 8'h00);
        wr8(THR, 8'h41);
        sink_ready = 1'b1;
        wait_cycles(3);
        sink_ready = 1'b0;
        tx_got_q.delete();
        if (irq !== 1'b0) $fatal(1, "[IRQ] irq with ETBEI=0");
        wr8(IER, 8'h02);
        expect_rd(IIR, 8'h02, "IRQ-ENABLE");
        // (e) THR write and last pop in the same cycle: FIFO never empty, no set
        wr8(FCR, 8'h01);
        wr8(IER, 8'h00);
        wr8(IER, 8'h02);                                     // pending (empty)
        wr8(THR, 8'h51);                                     // clears pending
        side_txr_req = 1'b1;
        wr8_side(THR, 8'h52);                                // pop 0x51 + push 0x52
        expect_rd(IIR, 8'hC1, "IRQ-THR+POP");
        sink_ready = 1'b1;
        wait_cycles(3);
        sink_ready = 1'b0;
        expect_rd(IIR, 8'hC2, "IRQ-THR+POP");                // drained: new empty event
        tx_got_q.delete();
        // (f) ETBEI rise in the same cycle as the last pop
        wr8(IER, 8'h00);
        wr8(THR, 8'h61);
        side_txr_req = 1'b1;
        wr8_side(IER, 8'h02);
        expect_rd(IIR, 8'hC2, "IRQ-RISE+POP");
        tx_got_q.delete();
        // (g) IIR read in the same cycle as the last TX pop: the read returns the old
        //     state (no THRE), the new empty event sets pending.
        wr8(IER, 8'h00);
        wr8(IER, 8'h02);                                     // pending (empty)
        wr8(THR, 8'h71);                                     // clears pending, count 1
        side_txr_req = 1'b1;
        expect_rd_side(IIR, 8'hC1, "IRQ-IIR+POP");
        if (dut.thre_pending !== 1'b1) $fatal(1, "[IRQ-IIR+POP] empty event lost");
        expect_rd(IIR, 8'hC2, "IRQ-IIR+POP");
        expect_rd(IIR, 8'hC1, "IRQ-IIR+POP");
        tx_got_q.delete();
        // (h) IER=0 written in the same cycle as the last TX pop: the new IER wins,
        //     pending stays 0 although the FIFO became empty (white-box: not visible
        //     through IIR while ETBEI=0).
        wr8(THR, 8'h72);                                     // IER=0x02, count 1, pending 0
        side_txr_req = 1'b1;
        wr8_side(IER, 8'h00);
        if (dut.thre_pending !== 1'b0 || irq !== 1'b0 || dut.tx_count !== 5'd0)
            $fatal(1, "[IRQ-IER0+POP] pending=%0b irq=%0b count=%0d", dut.thre_pending, irq, dut.tx_count);
        expect_rd(IIR, 8'hC1, "IRQ-IER0+POP");
        tx_got_q.delete();
        // (i) priority RLS > RDA > THRE
        wr8(IER, 8'h00);
        wr8(IER, 8'h07);                                     // THRE pending (empty)
        rx_inject(8'h45, 1'b1, 1'b0);
        expect_rd(IIR, 8'hC6, "IRQ-PRIO");
        expect_rd(LSR, 8'hE9, "IRQ-PRIO");                   // ack the head error
        expect_rd(IIR, 8'hC4, "IRQ-PRIO");
        expect_rd(RBR, 8'h45, "IRQ-PRIO");
        expect_rd(IIR, 8'hC2, "IRQ-PRIO");
        expect_rd(IIR, 8'hC1, "IRQ-PRIO");
        // OE drives RLS as well
        for (int i = 0; i < 17; i++) rx_inject(8'(i));
        expect_rd(IIR, 8'hC6, "IRQ-OE");
        expect_rd(LSR, 8'h63, "IRQ-OE");
        expect_rd(IIR, 8'hC4, "IRQ-OE");
        wr8(FCR, 8'h03);
        expect_rd(IIR, 8'hC1, "IRQ-OE");
        wr8(IER, 8'h00);
        if (irq !== 1'b0) $fatal(1, "[IRQ] irq after IER=0");
        $display("[T] IRQ: Linux THRE/TXEN probes, set/clear races, priority: PASS");
    endtask

    task automatic t_mcr_no_loopback();
        logic [7:0] exp[$];
        do_reset();
        wr8(FCR, 8'h01);
        wr8(MCR, 8'h10);                                     // loopback bit: stored only
        expect_rd(MCR, 8'h10, "MCR-LOOP");
        wr8(THR, 8'h4C);
        wr8(THR, 8'h4D);
        sink_ready = 1'b1;
        wait_cycles(5);
        exp = '{8'h4C, 8'h4D};
        expect_tx(exp, "MCR-LOOP");                          // real handoff despite MCR[4]
        expect_rd(LSR, 8'h60, "MCR-LOOP");                   // nothing looped into RX
        expect_rd(MSR, 8'h00, "MCR-LOOP");
        wr8(MCR, 8'h00);
        $display("[T] MCR[4] stored only, TX still handed off, no RX loopback: PASS");
    endtask

    task automatic t_diag_reset();
        do_reset();
        wr8(THR, 8'h01);
        wr8(THR, 8'h02);                                     // capacity 1: dropped
        rx_inject(8'h01);
        rx_inject(8'h02);
        if (diag_tx_overflow !== 1'b1 || diag_rx_overrun !== 1'b1) $fatal(1, "[DIAG] not set");
        expect_rd(LSR, 8'h03, "DIAG");                       // THRE=0, OE, DR
        if (diag_rx_overrun !== 1'b1) $fatal(1, "[DIAG] rx diag cleared by LSR read");
        do_reset();
        if (diag_tx_overflow !== 1'b0 || diag_rx_overrun !== 1'b0) $fatal(1, "[DIAG] not cleared by reset");
        $display("[T] sticky diagnostics and reset: PASS");
    endtask

    // ------------------------------------------------------------------
    // Main
    // ------------------------------------------------------------------
    initial begin
        rst = 1'b0;
        bus.valid = 1'b0;
        bus.wen = 1'b0;
        bus.addr = '0;
        bus.wdata = '0;
        bus.wmask = '0;
        rx_push = 1'b0;
        rx_data = 8'h00;
        rx_fe = 1'b0;
        rx_bi = 1'b0;
`ifdef TB_SIM_ERROR_PROFILE
        do_reset();
        wr8(THR, 8'h01);
        wr8(THR, 8'h02);                                     // dropped: RTL $error expected
        wait_cycles(5);
        $display("UART16550_REGS_SIM_ERROR_NOT_RAISED");
        $finish;
`else
        t_reset_values();
        t_lanes_dlab();
        t_held_valid();
        t_tx_fifo16();
        t_cap1();
        t_fcr_clear();
        t_dlab_tx();
        t_rx_fifo16();
        t_head_error();
        t_irq();
        t_mcr_no_loopback();
        t_diag_reset();
        $display("[TB] not covered here: PHY integration (separate TB), sim backend/DPI, CPU/Linux.");
        $display("UART16550_REGS_TB_PASS");
        $finish;
`endif
    end

endmodule : tb_uart16550_regs
