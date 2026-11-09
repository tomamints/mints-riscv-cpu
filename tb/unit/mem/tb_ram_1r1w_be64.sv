`timescale 1ns/1ps
// tb_ram_1r1w_be64: unit test for fpga/de0-cv/mem_probe/rtl/ram_1r1w_be64.sv
// (ASYNC=0) and ram_1r1w_be64_async.sv (ASYNC=1, latency-0 comparison model).
//
// Reference model: an independent byte array ref_mem[DEPTH][8] in the TB.
// Timing discipline: inputs are driven at negedge; the DUT samples them at the
// following posedge (edge N); results are checked at the next negedge, i.e.
// after edge N and before edge N+1 (the consumer's sample point).
//   sync  : rdata after edge N == word read at edge N (pre-write value), and it
//           is held while re = 0.
//   async : rdata == ref_mem[raddr] combinationally (checked at negedge).
//
// Profiles:
//   default                     : all tests; a collision is never generated, and the
//                                 RTL assertion makes any accidental one fatal.
//   +define+TB_COLLISION_PROFILE : one intentional collision; the RTL $fatal is
//                                 EXPECTED (non-zero exit). Reaching the end prints
//                                 RAM_TB_COLLISION_NOT_RAISED.
// Parameters: DEPTH (128 or 32), ASYNC (0 or 1), STYLE (0..2, no effect in sim).
module tb_ram_1r1w_be64 #(
    parameter int unsigned DEPTH = 128,
    parameter int unsigned ASYNC = 0,
    parameter int unsigned STYLE = 2
);
    localparam int unsigned AW = $clog2(DEPTH);

    timeunit 1ns;
    timeprecision 1ps;

    // Clock period 10 ns: negedge drive at t, posedge at t + 5 ns.
    localparam real SETTLE_NS = 1.0;   // check point after the negedge drive (< 5 ns to posedge)

    logic clk = 1'b0;
    always #5 clk = ~clk;
    int unsigned n_settle_checks = 0;

    initial begin
        #(50_000_000);
        $fatal(1, "[TB] WATCHDOG");
    end

    logic          we = 1'b0;
    logic [AW-1:0] waddr = '0;
    logic [7:0]    wbe = 8'h00;
    logic [63:0]   wdata = '0;
    logic          re = 1'b0;
    logic [AW-1:0] raddr = '0;
    logic [63:0]   rdata;

    if (ASYNC != 0) begin : g_async
        ram_1r1w_be64_async #(.DEPTH(DEPTH)) dut (
            .clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata),
            .re(re), .raddr(raddr), .rdata(rdata));
    end else begin : g_sync
        ram_1r1w_be64 #(.DEPTH(DEPTH), .STYLE(STYLE)) dut (
            .clk(clk), .we(we), .waddr(waddr), .wbe(wbe), .wdata(wdata),
            .re(re), .raddr(raddr), .rdata(rdata));
    end

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------
    logic [7:0] ref_mem [DEPTH][8];
    bit         ref_init [DEPTH];      // word fully written at least once
    logic [63:0] exp_rdata;            // sync: value the DUT must hold
    bit          exp_valid = 1'b0;     // sync: exp_rdata defined
    int unsigned n_reads = 0;
    int unsigned n_writes = 0;
    int unsigned n_checks = 0;

    function automatic logic [63:0] ref_word(input logic [AW-1:0] a);
        logic [63:0] w;
        for (int i = 0; i < 8; i++) w[i*8 +: 8] = ref_mem[a][i];
        return w;
    endfunction

    // One clock cycle: drive at negedge, edge N, then check at the next negedge.
    task automatic cycle(input logic w_en, input logic [AW-1:0] w_a, input logic [7:0] w_be,
                         input logic [63:0] w_d, input logic r_en, input logic [AW-1:0] r_a);
        logic [63:0] pre_read;
        we = w_en; waddr = w_a; wbe = w_be; wdata = w_d;
        re = r_en; raddr = r_a;
        pre_read = ref_word(r_a);                        // value before edge N
        // Sync bank: changing re/raddr/we/... must not change rdata before the next
        // rising edge (no combinational path from the inputs to rdata). Checked
        // SETTLE_NS after the negedge drive, still well before the posedge.
        if (ASYNC == 0 && exp_valid) begin
            #(SETTLE_NS);
            if (rdata !== exp_rdata)
                $fatal(1, "[SYNC-HOLD] rdata changed before the clock edge: %016x expected %016x", rdata, exp_rdata);
            n_settle_checks++;
        end
        @(posedge clk);                                  // edge N
        if (w_en) begin
            for (int i = 0; i < 8; i++) if (w_be[i]) ref_mem[w_a][i] = w_d[i*8 +: 8];
            if (w_be != 8'h00) n_writes++;
            if (w_be == 8'hFF) ref_init[w_a] = 1'b1;
        end
        if (r_en) begin
            exp_rdata = pre_read;
            exp_valid = 1'b1;
            n_reads++;
        end
        @(negedge clk);                                  // between edge N and N+1
        we = 1'b0; wbe = 8'h00; re = 1'b0;
        if (ASYNC == 0) begin
            if (exp_valid) begin
                if (rdata !== exp_rdata)
                    $fatal(1, "[SYNC] rdata %016x expected %016x (raddr=%0d)", rdata, exp_rdata, raddr);
                n_checks++;
            end
        end else begin
            if (ref_init[raddr]) begin
                if (rdata !== ref_word(raddr))
                    $fatal(1, "[ASYNC] rdata %016x expected %016x (raddr=%0d)", rdata, ref_word(raddr), raddr);
                n_checks++;
            end
        end
    endtask

    task automatic write_full(input logic [AW-1:0] a, input logic [63:0] d);
        cycle(1'b1, a, 8'hFF, d, 1'b0, '0);
    endtask

    task automatic read_check(input logic [AW-1:0] a);
        cycle(1'b0, '0, 8'h00, '0, 1'b1, a);
        if (rdata !== ref_word(a)) $fatal(1, "[READ] addr %0d: %016x expected %016x", a, rdata, ref_word(a));
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic t_init();
        for (int a = 0; a < DEPTH; a++) write_full(AW'(a), {32'hC0DE_0000 | 32'(a), 32'h5A5A_0000 | 32'(a)});
        for (int a = 0; a < DEPTH; a++) read_check(AW'(a));
        $display("[T] fill and read back all %0d words: PASS", DEPTH);
    endtask

    task automatic t_all_masks();
        logic [AW-1:0] addrs [3];
        addrs = '{AW'(0), AW'(DEPTH / 2), AW'(DEPTH - 1)};
        foreach (addrs[k]) begin
            for (int m = 0; m < 256; m++) begin
                write_full(addrs[k], 64'h0123_4567_89AB_CDEF);
                cycle(1'b1, addrs[k], 8'(m), 64'hFEDC_BA98_7654_3210 ^ {8{8'(m)}}, 1'b0, '0);
                read_check(addrs[k]);
                if (addrs[k] != 0) read_check(addrs[k] - 1'b1);          // neighbours untouched
                if (addrs[k] != AW'(DEPTH - 1)) read_check(addrs[k] + 1'b1);
            end
        end
        $display("[T] all 256 byte masks at addresses 0, %0d, %0d (+ neighbours): PASS", DEPTH / 2, DEPTH - 1);
    endtask

    task automatic t_endpoints();
        for (int e = 0; e < 2; e++) begin
            logic [AW-1:0] a;
            a = (e == 0) ? AW'(0) : AW'(DEPTH - 1);
            write_full(a, 64'h0); read_check(a);
            write_full(a, '1);    read_check(a);
            for (int b = 0; b < 64; b++) begin
                write_full(a, 64'(1) << b);    read_check(a);       // walking 1
                write_full(a, ~(64'(1) << b)); read_check(a);       // walking 0
            end
        end
        $display("[T] endpoints, all-0/all-1, walking 1/0: PASS");
    endtask

    task automatic t_latency_hold();
        if (ASYNC != 0) begin
            $display("[T] latency/hold: ASYNC model has latency 0 (checked every cycle), re ignored: PASS");
            return;
        end
        write_full(AW'(3), 64'hAAAA_0000_0000_0003);
        write_full(AW'(4), 64'hBBBB_0000_0000_0004);
        // read at edge N: valid after edge N (checked inside cycle at the negedge)
        cycle(1'b0, '0, 8'h00, '0, 1'b1, AW'(3));
        if (rdata !== 64'hAAAA_0000_0000_0003) $fatal(1, "[LAT] read not available after edge N");
        // re = 0 for several cycles while the same address is rewritten: rdata holds
        for (int i = 0; i < 4; i++) begin
            cycle(1'b1, AW'(3), 8'hFF, 64'(i), 1'b0, '0);
            if (rdata !== 64'hAAAA_0000_0000_0003) $fatal(1, "[HOLD] rdata changed while re=0");
        end
        // back-to-back reads of different addresses
        cycle(1'b0, '0, 8'h00, '0, 1'b1, AW'(4));
        if (rdata !== 64'hBBBB_0000_0000_0004) $fatal(1, "[B2B] first");
        cycle(1'b0, '0, 8'h00, '0, 1'b1, AW'(3));
        if (rdata !== 64'd3) $fatal(1, "[B2B] second");
        // read and write of DIFFERENT addresses in the same cycle
        cycle(1'b1, AW'(5), 8'hFF, 64'h55, 1'b1, AW'(4));
        if (rdata !== 64'hBBBB_0000_0000_0004) $fatal(1, "[RW-DIFF]");
        // wbe = 0 with the same address is not a write: allowed, returns stored value
        cycle(1'b1, AW'(4), 8'h00, '1, 1'b1, AW'(4));
        if (rdata !== 64'hBBBB_0000_0000_0004) $fatal(1, "[WBE0-SAME] wbe=0 changed data or failed");
        $display("[T] 1-cycle read latency, re hold, back-to-back, R/W different addr, wbe=0 same addr: PASS");
    endtask

    task automatic t_random();
        int unsigned seed;
        logic          w_en;
        logic [AW-1:0] w_a;
        logic [7:0]    w_be;
        logic [63:0]   w_d;
        logic          r_en;
        logic [AW-1:0] r_a;
        seed = 32'd20261109;
        void'($urandom(seed));
        for (int i = 0; i < 10000; i++) begin
            w_en = 1'($urandom_range(0, 1));
            w_a  = AW'($urandom_range(0, DEPTH - 1));
            w_be = 8'($urandom);
            w_d  = {$urandom, $urandom};
            r_en = 1'($urandom_range(0, 1));
            r_a  = AW'($urandom_range(0, DEPTH - 1));
            // never generate the forbidden collision in the normal profile
            if (w_en && w_be != 8'h00 && r_en && w_a == r_a) r_a = r_a + 1'b1;
            cycle(w_en, w_a, w_be, w_d, r_en, r_a);
        end
        $display("[T] 10000 random cycles (fixed seed, collisions excluded): PASS");
    endtask

    initial begin
        foreach (ref_init[a]) ref_init[a] = 1'b0;
        @(negedge clk);
`ifdef TB_COLLISION_PROFILE
        write_full(AW'(7), 64'h1111_2222_3333_4444);
        cycle(1'b1, AW'(7), 8'h01, 64'hFF, 1'b1, AW'(7));   // forbidden: RTL $fatal expected
        repeat (3) @(negedge clk);
        $display("RAM_TB_COLLISION_NOT_RAISED");
        $finish;
`else
        $display("[TB] DEPTH=%0d ASYNC=%0d STYLE=%0d", DEPTH, ASYNC, STYLE);
        t_init();
        t_all_masks();
        t_endpoints();
        t_latency_hold();
        t_random();
        $display("[TB] writes=%0d reads=%0d checks=%0d pre-edge-hold-checks=%0d", n_writes, n_reads, n_checks, n_settle_checks);
        if (ASYNC == 0 && n_settle_checks == 0) $fatal(1, "[TB] no pre-edge hold check executed");
        $display("RAM_1R1W_BE64_TB_PASS depth=%0d async=%0d", DEPTH, ASYNC);
        $finish;
`endif
    end

endmodule : tb_ram_1r1w_be64
