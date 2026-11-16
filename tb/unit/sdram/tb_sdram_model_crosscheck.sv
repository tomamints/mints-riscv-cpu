`timescale 1ns/1ps
// Cross-check of the clock-sampled sdram_cycle_model16 against the timing-mode
// sdram_pin_model16 (C3 M3b). Two identical stacks (adapter -> bridge64 ->
// native16) receive the same deterministic request stream in lock step:
//   stack P: pin model (reference, quarter-period memory clock),
//   stack C: cycle model (UNWRITTEN = 16'hcafe like the pin model).
// Every response must arrive in the same cycle on both stacks with identical
// read data, equal to an independent shadow memory. Traffic: all 256 masks on
// the top word with readback, first/last byte/halfword/word offsets, and 600
// fixed-seed mixed requests over the bottom/top of 64 MiB.
// Mutation build TB_MUTATE_DELAY delays stack C's read data by one cycle; the
// cross-check must fail (proves a capture-edge error in the model is caught).
module tb_sdram_model_crosscheck #(parameter int unsigned CLK_HZ = 20_000_000);
    logic clk = 0;
    always #(500_000_000.0 / CLK_HZ) clk = ~clk;
    logic rst_n = 0;
    localparam logic [63:0] SIZE = 64'h0400_0000;

    // shared request
    logic m_valid = 0, m_wen = 0; logic [63:0] m_addr = 0, m_wdata = 0; logic [7:0] m_wmask = 0;
    Membus up_p(); Membus up_c();
    assign up_p.valid = m_valid; assign up_p.addr = m_addr; assign up_p.wen = m_wen;
    assign up_p.wdata = m_wdata; assign up_p.wmask = m_wmask;
    assign up_c.valid = m_valid; assign up_c.addr = m_addr; assign up_c.wen = m_wen;
    assign up_c.wdata = m_wdata; assign up_c.wmask = m_wmask;

    // ---- stack P (pin model) ----
    logic pv, pr, pw, prv, pre; logic [63:0] pa, pwd, prd; logic [7:0] pbe;
    logic p_nv, p_nr, p_nw, p_nrv, p_oe, p_cke, p_cs, p_ras, p_cas, p_we;
    logic [24:0] p_na; logic [15:0] p_nwd, p_nrd, p_do, p_di; logic [1:0] p_nbe, p_ba, p_dqm; logic [12:0] p_a;
    membus_sdram_adapter ad_p(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0), .up(up_p),
        .req_valid(pv), .req_ready(pr), .req_addr(pa), .req_write(pw), .req_wdata(pwd), .req_be(pbe),
        .rsp_valid(prv), .rsp_data(prd), .rsp_error(pre), .fault(), .fault_seen(), .fault_kind(),
        .fault_offset(), .fault_abs(), .fault_wen());
    sdram_bridge64 br_p(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0), .req_valid(pv), .req_ready(pr),
        .req_addr(pa), .req_write(pw), .req_wdata(pwd), .req_be(pbe), .rsp_valid(prv), .rsp_data(prd),
        .rsp_error(pre), .native_valid(p_nv), .native_ready(p_nr), .native_addr(p_na),
        .native_write(p_nw), .native_wdata(p_nwd), .native_be(p_nbe), .native_rsp_valid(p_nrv),
        .native_rsp_data(p_nrd));
    sdram_native16 #(.CLK_HZ(CLK_HZ)) nt_p(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0),
        .req_valid(p_nv), .req_ready(p_nr), .req_addr(p_na), .req_write(p_nw), .req_wdata(p_nwd),
        .req_be(p_nbe), .rsp_valid(p_nrv), .rsp_data(p_nrd), .init_done(), .dram_addr(p_a),
        .dram_ba(p_ba), .dram_dqm(p_dqm), .dram_cke(p_cke), .dram_cs_n(p_cs), .dram_ras_n(p_ras),
        .dram_cas_n(p_cas), .dram_we_n(p_we), .dq_in(p_di), .dq_out(p_do), .dq_oe(p_oe));
    sdram_pin_model16 #(.CLK_HZ(CLK_HZ)) pin(.clk(clk), .rst_n(rst_n), .a(p_a), .ba(p_ba), .dqm(p_dqm),
        .cke(p_cke), .csn(p_cs), .rasn(p_ras), .casn(p_cas), .wen(p_we), .oe(p_oe), .dout(p_do), .din(p_di));

    // ---- stack C (cycle model) ----
    logic cv, cr, cw, crv, cre; logic [63:0] ca, cwd, crd; logic [7:0] cbe;
    logic c_nv, c_nr, c_nw, c_nrv, c_oe, c_cke, c_cs, c_ras, c_cas, c_we;
    logic [24:0] c_na; logic [15:0] c_nwd, c_nrd, c_do, c_di, c_di_model; logic [1:0] c_nbe, c_ba, c_dqm; logic [12:0] c_a;
    membus_sdram_adapter ad_c(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0), .up(up_c),
        .req_valid(cv), .req_ready(cr), .req_addr(ca), .req_write(cw), .req_wdata(cwd), .req_be(cbe),
        .rsp_valid(crv), .rsp_data(crd), .rsp_error(cre), .fault(), .fault_seen(), .fault_kind(),
        .fault_offset(), .fault_abs(), .fault_wen());
    sdram_bridge64 br_c(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0), .req_valid(cv), .req_ready(cr),
        .req_addr(ca), .req_write(cw), .req_wdata(cwd), .req_be(cbe), .rsp_valid(crv), .rsp_data(crd),
        .rsp_error(cre), .native_valid(c_nv), .native_ready(c_nr), .native_addr(c_na),
        .native_write(c_nw), .native_wdata(c_nwd), .native_be(c_nbe), .native_rsp_valid(c_nrv),
        .native_rsp_data(c_nrd));
    sdram_native16 #(.CLK_HZ(CLK_HZ)) nt_c(.clk(clk), .rst_n(rst_n), .soft_reset(1'b0),
        .req_valid(c_nv), .req_ready(c_nr), .req_addr(c_na), .req_write(c_nw), .req_wdata(c_nwd),
        .req_be(c_nbe), .rsp_valid(c_nrv), .rsp_data(c_nrd), .init_done(), .dram_addr(c_a),
        .dram_ba(c_ba), .dram_dqm(c_dqm), .dram_cke(c_cke), .dram_cs_n(c_cs), .dram_ras_n(c_ras),
        .dram_cas_n(c_cas), .dram_we_n(c_we), .dq_in(c_di), .dq_out(c_do), .dq_oe(c_oe));
    sdram_cycle_model16 #(.CLK_HZ(CLK_HZ), .UNWRITTEN(16'hcafe)) cyc_model(.clk(clk), .rst_n(rst_n),
        .a(c_a), .ba(c_ba), .dqm(c_dqm), .cke(c_cke), .csn(c_cs), .rasn(c_ras), .casn(c_cas), .wen(c_we),
        .oe(c_oe), .dout(c_do), .din(c_di_model));
`ifdef TB_MUTATE_DELAY
    logic [15:0] c_di_q = '0;
    always @(posedge clk) c_di_q <= c_di_model;
    assign c_di = c_di_q;
`else
    assign c_di = c_di_model;
`endif

    // ---- reference and lock-step checks ----
    logic [63:0] shadow [logic [63:0]];
    function automatic logic [63:0] ref_read(input logic [63:0] w);
        return shadow.exists(w) ? shadow[w] : 64'hcafe_cafe_cafe_cafe;
    endfunction
    function automatic logic [63:0] expand(input logic [7:0] m);
        logic [63:0] r; for (int b = 0; b < 8; b++) r[b*8 +: 8] = {8{m[b]}}; return r;
    endfunction
    longint unsigned cyc = 0, n_req = 0, n_reads = 0;
    always @(posedge clk) begin
        cyc++;
        if (up_p.ready !== up_c.ready) $fatal(1, "[LOCKSTEP] ready differs P=%b C=%b (cyc %0d)", up_p.ready, up_c.ready, cyc);
        if (up_p.rvalid !== up_c.rvalid) $fatal(1, "[LOCKSTEP] response cycle differs P=%b C=%b (cyc %0d)", up_p.rvalid, up_c.rvalid, cyc);
        if (up_p.rvalid && up_p.rdata !== up_c.rdata)
            $fatal(1, "[CROSS] read data P=%h C=%h (cyc %0d)", up_p.rdata, up_c.rdata, cyc);
    end

    task automatic req(input logic [63:0] a, input bit w, input logic [63:0] d, input logic [7:0] m);
        logic [63:0] word; int waited;
        word = a & ~64'h7;
        @(negedge clk); m_valid = 1; m_addr = a; m_wen = w; m_wdata = d; m_wmask = m;
        waited = 0;
        do begin @(posedge clk); waited++; if (waited > 100000) $fatal(1, "[REQ] not accepted"); end
        while (!(up_p.valid && up_p.ready));
        @(negedge clk); m_valid = 0;
        waited = 0;
        do begin @(posedge clk); waited++; if (waited > 100000) $fatal(1, "[REQ] no response"); end
        while (!up_p.rvalid);
        if (!w && up_p.rdata !== ref_read(word))
            $fatal(1, "[SHADOW] read %h: P=%h expected %h", word, up_p.rdata, ref_read(word));
        if (w) shadow[word] = (ref_read(word) & ~expand(m)) | (d & expand(m));
        else n_reads++;
        n_req++;
    endtask

    logic [63:0] rng = 64'h2026_1110_C0C0_0001;
    function automatic logic [63:0] xs(input logic [63:0] s);
        logic [63:0] x; x = s; x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x;
    endfunction
    initial begin
        repeat (5) @(posedge clk);
        @(negedge clk); #2 rst_n = 1;
        wait (up_p.ready && up_c.ready);
        for (int m = 0; m < 256; m++) begin
            req(SIZE - 8, 1, 64'h0123_4567_89ab_cdef, 8'hff);
            req(SIZE - 8, 1, 64'hfedc_ba98_7654_3210 ^ 64'(m), 8'(m));
            req(SIZE - 8, 0, '0, '0);
        end
        req(64'h0, 1, 64'h0000_0000_0000_00a5, 8'h01);
        req(SIZE - 1, 1, 64'h5a00_0000_0000_0000, 8'h80);
        req(SIZE - 2, 1, 64'h7e3c_0000_0000_0000, 8'hc0);
        req(SIZE - 4, 1, 64'h89ab_cdef_0000_0000, 8'hf0);
        req(64'h0, 0, '0, '0); req(SIZE - 8, 0, '0, '0);
        req(64'h100, 0, '0, '0);                          // never written: cafe on both models
        for (int i = 0; i < 600; i++) begin
            logic [63:0] a; int unsigned size, off, word;
            rng = xs(rng); word = int'(rng % 64);
            a = (word < 32) ? 64'(word) * 8 : SIZE - 64'(64 - word) * 8;
            rng = xs(rng); size = 1 << int'(rng % 4);
            rng = xs(rng); off = int'(rng % (8 / size)) * size;
            rng = xs(rng);
            req(a + 64'(off), rng[0], rng ^ 64'h5a5a_a5a5_0f0f_f0f0, 8'(((1 << size) - 1) << off));
        end
        $display("SDRAM_MODEL_CROSSCHECK_PASS clk=%0d requests=%0d reads=%0d cycles=%0d", CLK_HZ, n_req, n_reads, cyc);
        $finish;
    end
    initial begin #4_000_000_000; $fatal(1, "[WATCHDOG]"); end
endmodule
