`timescale 1ns/1ps
// Unit TB for rtl/bus/membus_sdram_adapter.sv (C3 M3a):
// adapter -> sdram_bridge64 -> sdram_native16 (CLK_HZ) -> sdram_pin_model16.
//
// Phases
//   directed: all 256 byte masks on the top 8-byte word (each followed by a
//             readback), zero-mask writes, explicit first/last byte, halfword
//             and word offsets at both ends of the 64 MiB region;
//   random:   sizes 1/2/4/8 at lane-aligned addr[2:0], read/write mix,
//             pre-fire withdraw/change, bottom/top addresses, one soft_reset
//             cancel of an outstanding read;
//   fault:    out-of-range offsets (64 MiB, far, wrapping) -> range fault.
// Oracles
//   - shadow memory (unwritten = 16'hcafe per halfword, the model default);
//   - independent pin monitor on the device clock: every write response must
//     be preceded (after its acceptance) by exactly 4 WRITE commands carrying
//     the lane data with DQM = ~mask per byte (a zero mask writes no byte), in
//     halfword order; every read response by exactly 4 READs. Each word's 4
//     physical locations (bank,row,col) are learned on first use and must stay
//     the same, and no location may belong to two words (no aliasing). This
//     does not assume the controller's address mapping.
//   - bridge handshake (req_valid && req_ready) exactly in in-range upstream
//     handshake cycles; the bridge leaves IDLE only on its handshake;
//   - ready independent of upstream valid (negedge probe; reset edges placed
//     after the probe); no handshake/response during reset; one response per
//     request; accepted == responses + cancels.
module tb_membus_sdram_adapter #(parameter int unsigned CLK_HZ = 20_000_000);
    logic clk = 0;
    always #(500_000_000.0 / CLK_HZ) clk = ~clk;
    logic rst_n = 0, soft_reset = 0;

    Membus up_bus();
    logic req_valid, req_ready, req_write, rsp_valid, rsp_error;
    logic [63:0] req_addr, req_wdata, rsp_data;
    logic [7:0] req_be;
    logic fault, fault_seen, fault_wen;
    logic [1:0] fault_kind;
    logic [63:0] fault_offset, fault_abs;
    membus_sdram_adapter dut(.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .up(up_bus),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr), .req_write(req_write),
        .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(rsp_valid), .rsp_data(rsp_data),
        .rsp_error(rsp_error), .fault(fault), .fault_seen(fault_seen), .fault_kind(fault_kind),
        .fault_offset(fault_offset), .fault_abs(fault_abs), .fault_wen(fault_wen));

    logic nv, nready, nwr, nrv, oe, cke, csn, rasn, casn, wen;
    logic [24:0] na; logic [15:0] nwd, nrd, dout, din; logic [1:0] nbe, mb, dqm; logic [12:0] ma;
    sdram_bridge64 bridge(.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr), .req_write(req_write),
        .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(rsp_valid), .rsp_data(rsp_data),
        .rsp_error(rsp_error), .native_valid(nv), .native_ready(nready), .native_addr(na),
        .native_write(nwr), .native_wdata(nwd), .native_be(nbe), .native_rsp_valid(nrv),
        .native_rsp_data(nrd));
    sdram_native16 #(.CLK_HZ(CLK_HZ)) native(.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset),
        .req_valid(nv), .req_ready(nready), .req_addr(na), .req_write(nwr), .req_wdata(nwd),
        .req_be(nbe), .rsp_valid(nrv), .rsp_data(nrd), .init_done(), .dram_addr(ma), .dram_ba(mb),
        .dram_dqm(dqm), .dram_cke(cke), .dram_cs_n(csn), .dram_ras_n(rasn), .dram_cas_n(casn),
        .dram_we_n(wen), .dq_in(din), .dq_out(dout), .dq_oe(oe));
    sdram_pin_model16 #(.CLK_HZ(CLK_HZ)) model(.clk(clk), .rst_n(rst_n), .a(ma), .ba(mb), .dqm(dqm),
        .cke(cke), .csn(csn), .rasn(rasn), .casn(casn), .wen(wen), .oe(oe), .dout(dout), .din(din));

    // ---------------- RNG ----------------
    logic [63:0] rng = 64'h2026_1110_ADA9_0001;
    function automatic logic [63:0] xs(input logic [63:0] s);
        logic [63:0] x; x = s; x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x;
    endfunction
    function automatic int unsigned rnd(input int unsigned n);   // 0..n-1
        rng = xs(rng); return int'(rng % 64'(n));
    endfunction

    // ---------------- reference ----------------
    localparam logic [63:0] SIZE = 64'h0400_0000;
    logic [63:0] shadow [logic [63:0]];
    function automatic logic [63:0] ref_read(input logic [63:0] w);
        return shadow.exists(w) ? shadow[w] : 64'hcafe_cafe_cafe_cafe;
    endfunction
    function automatic logic [63:0] expand(input logic [7:0] m);
        logic [63:0] r; for (int b = 0; b < 8; b++) r[b*8 +: 8] = {8{m[b]}}; return r;
    endfunction

    // ---------------- pin monitor (device clock) ----------------
    wire mclk;
    assign #(250_000_000.0 / CLK_HZ) mclk = clk;
    typedef struct packed { logic [1:0] b; logic [12:0] r; logic [9:0] c; } loc_t;
    typedef struct packed { loc_t l; logic [15:0] d; logic [1:0] m; } wev_t;
    logic [12:0] open_row [4];
    wev_t wr_ev[$];
    loc_t rd_ev[$];
    loc_t word_loc [logic [63:0]][4];
    bit   word_known [logic [63:0]];
    logic [63:0] loc_owner [loc_t];
    always @(posedge mclk) if (rst_n) begin
        unique case ({csn, rasn, casn, wen})
            4'b0011: open_row[mb] = ma;                                        // ACTIVE
            4'b0100: begin                                                     // WRITE
                if (!oe) $fatal(1, "[PIN] WRITE without DQ drive");
                wr_ev.push_back('{l: '{b: mb, r: open_row[mb], c: ma[9:0]}, d: dout, m: dqm});
            end
            4'b0101: rd_ev.push_back('{b: mb, r: open_row[mb], c: ma[9:0]});   // READ
            default: ;
        endcase
    end

    task automatic check_locations(input logic [63:0] w, input loc_t l [4], input string what);
        for (int j = 0; j < 4; j++) begin
            if (word_known.exists(w) && word_loc[w][j] != l[j])
                $fatal(1, "[PIN] %s word %h half %0d moved: %p -> %p", what, w, j, word_loc[w][j], l[j]);
            if (loc_owner.exists(l[j]) && loc_owner[l[j]] != w)
                $fatal(1, "[PIN] alias: %p used by words %h and %h", l[j], loc_owner[l[j]], w);
        end
        for (int j = 0; j < 4; j++) begin
            for (int k = j + 1; k < 4; k++)
                if (l[j] == l[k]) $fatal(1, "[PIN] %s word %h halves %0d/%0d share a location", what, w, j, k);
            word_loc[w][j] = l[j]; loc_owner[l[j]] = w;
        end
        word_known[w] = 1;
    endtask

    // ---------------- master ----------------
    logic m_valid = 0, m_wen = 0; logic [63:0] m_addr = 0, m_wdata = 0; logic [7:0] m_wmask = 0;
    assign up_bus.valid = m_valid; assign up_bus.addr = m_addr; assign up_bus.wen = m_wen;
    assign up_bus.wdata = m_wdata; assign up_bus.wmask = m_wmask;
    bit random_on = 0;
    task automatic new_payload();
        int unsigned size, off, word;
        word = rnd(64);
        m_addr = (word < 32) ? 64'(word) * 8 : SIZE - 64'(64 - word) * 8;   // bottom/top of 64 MiB
        size = 1 << rnd(4);
        off = rnd(8 / size) * size;
        m_addr += 64'(off);
        m_wen = rnd(2) == 1;
        rng = xs(rng); m_wdata = rng;
        m_wmask = 8'(((1 << size) - 1) << off);
    endtask

    bit pending = 0, pend_wen; logic [63:0] pend_word, pend_wdata; logic [7:0] pend_wmask;
    logic [63:0] last_rdata;
    longint unsigned cyc = 0, n_acc = 0, n_rsp = 0, n_w = 0, n_withdraw = 0, n_change = 0, n_cancel = 0, n_zero_mask = 0;
    bit [255:0] masks_seen = '0;
    bit in_fault_phase = 0;
    logic [2:0] bridge_state_q;
    logic bridge_fire_q;

    always @(negedge clk) begin
        bit r0;
        r0 = up_bus.ready;
        if (random_on && rst_n && !soft_reset) begin
            if (!pending || up_bus.rvalid) begin
                if (m_valid) begin
                    case (rnd(10)) 0: begin m_valid = 0; n_withdraw++; end
                                   1: begin new_payload(); n_change++; end
                                   default: ; endcase
                end else if (rnd(10) < 7) begin
                    m_valid = 1; new_payload();
                end
            end else m_valid = 0;
        end else if (random_on) m_valid = 0;
        #1;
        if (up_bus.ready !== r0) $fatal(1, "[READY] ready changed with upstream valid/payload (cyc %0d)", cyc);
    end

    always @(posedge clk) begin
        bit up_fire;
        cyc++;
        up_fire = up_bus.valid && up_bus.ready;
        if ((req_valid && req_ready) !== (up_fire && up_bus.addr < SIZE))
            $fatal(1, "[REQ] bridge handshake %b vs in-range upstream handshake %b", req_valid && req_ready, up_fire && up_bus.addr < SIZE);
        // the bridge may leave IDLE only one edge after its own handshake
        if (rst_n && bridge_state_q == 3'(bridge.IDLE) && 3'(bridge.state) != 3'(bridge.IDLE) && !bridge_fire_q && !soft_reset)
            $fatal(1, "[REQ] bridge left IDLE without a handshake");
        bridge_state_q = 3'(bridge.state);
        bridge_fire_q = req_valid && req_ready;
        if ((!rst_n || soft_reset) && (up_bus.ready || up_bus.rvalid))
            $fatal(1, "[RESET] handshake/response during reset");
        if (up_bus.rvalid) begin
            loc_t l [4];
            if (!pending) $fatal(1, "[RSP] response without outstanding request");
            if (pend_wen) begin
                if (wr_ev.size() != 4) $fatal(1, "[PIN] write %h: %0d WRITE commands before the response", pend_word, wr_ev.size());
                for (int j = 0; j < 4; j++) begin
                    logic [1:0] want_dqm; logic [15:0] want;
                    want_dqm = ~pend_wmask[2*j +: 2];
                    want = pend_wdata[16*j +: 16];
                    l[j] = wr_ev[j].l;
                    if (wr_ev[j].m !== want_dqm)
                        $fatal(1, "[PIN] write %h half %0d DQM %b expected %b", pend_word, j, wr_ev[j].m, want_dqm);
                    for (int b = 0; b < 2; b++)
                        if (!want_dqm[b] && wr_ev[j].d[8*b +: 8] !== want[8*b +: 8])
                            $fatal(1, "[PIN] write %h half %0d byte %0d data %h expected %h", pend_word, j, b, wr_ev[j].d[8*b +: 8], want[8*b +: 8]);
                end
                check_locations(pend_word, l, "write");
                shadow[pend_word] = (ref_read(pend_word) & ~expand(pend_wmask)) | (pend_wdata & expand(pend_wmask));
            end else begin
                if (rd_ev.size() != 4) $fatal(1, "[PIN] read %h: %0d READ commands", pend_word, rd_ev.size());
                for (int j = 0; j < 4; j++) l[j] = rd_ev[j];
                check_locations(pend_word, l, "read");
                if (up_bus.rdata !== ref_read(pend_word))
                    $fatal(1, "[RSP] read %h: got %h expected %h", pend_word, up_bus.rdata, ref_read(pend_word));
                last_rdata = up_bus.rdata;
            end
            pending = 0; n_rsp++;
        end
        if (up_fire && !in_fault_phase) begin
            if (pending) $fatal(1, "[ACC] accept while outstanding");
            pending = 1; pend_wen = up_bus.wen; pend_word = up_bus.addr & ~64'h7;
            pend_wdata = up_bus.wdata; pend_wmask = up_bus.wmask; n_acc++;
            if (up_bus.wen) begin n_w++; masks_seen[up_bus.wmask] = 1; if (up_bus.wmask == 0) n_zero_mask++; end
            wr_ev.delete(); rd_ev.delete();
        end
    end

    // ---------------- directed request ----------------
    task automatic dreq(input logic [63:0] a, input bit w, input logic [63:0] d, input logic [7:0] m);
        int waited;
        @(negedge clk); m_valid = 1; m_addr = a; m_wen = w; m_wdata = d; m_wmask = m;
        waited = 0;
        do begin @(posedge clk); waited++; if (waited > 100000) $fatal(1, "[DIRECTED] not accepted"); end
        while (!(up_bus.valid && up_bus.ready));
        @(negedge clk); m_valid = 0;
        while (pending) @(posedge clk);
    endtask

    task automatic fault_case(input logic [63:0] off, input bit w);
        int waited;
        @(negedge clk); m_valid = 1; m_addr = off; m_wen = w; m_wdata = '1; m_wmask = 8'hff;
        waited = 0;
        do begin @(posedge clk); waited++; if (waited > 2000) $fatal(1, "[FAULT] not accepted"); end
        while (!(up_bus.valid && up_bus.ready));
        #1;    // the fault latched at this acceptance edge
        if (!fault || !fault_seen || fault_kind != 2'd1 || fault_offset !== off || fault_wen !== w ||
            fault_abs !== 64'h8000_0000 + (off & ~64'h7))
            $fatal(1, "[FAULT] snapshot fault=%b seen=%b kind=%0d off=%h abs=%h wen=%b", fault, fault_seen, fault_kind, fault_offset, fault_abs, fault_wen);
        repeat (200) begin
            @(posedge clk); #1;
            if (up_bus.ready || up_bus.rvalid || req_valid || 3'(bridge.state) != 3'(bridge.IDLE))
                $fatal(1, "[FAULT] handshake/response/request while faulted");
        end
        @(negedge clk); m_valid = 0; #2 soft_reset = 1;
        repeat (3) @(posedge clk);
        @(negedge clk); #2 soft_reset = 0;
        @(posedge clk); #1;
        if (fault || !fault_seen) $fatal(1, "[FAULT] soft_reset must clear fault and keep fault_seen");
    endtask

    localparam logic [63:0] TOP = SIZE - 8;
    initial begin
        repeat (5) @(posedge clk);
        // reset/soft_reset edges are placed after the negedge ready probe (#1)
        @(negedge clk); #2 rst_n = 1;
        wait (req_ready);
        // ---- directed: all 256 masks on the top word, each with a readback ----
        for (int m = 0; m < 256; m++) begin
            dreq(TOP, 1, 64'h0123_4567_89ab_cdef, 8'hff);
            dreq(TOP, 1, 64'hfedc_ba98_7654_3210 ^ 64'(m), 8'(m));
            dreq(TOP, 0, '0, '0);
        end
        // zero mask on a written word changes nothing (pins: DQM=11 on all halves)
        dreq(64'h0, 1, 64'h1111_2222_3333_4444, 8'hff);
        dreq(64'h0, 1, '1, 8'h00);
        dreq(64'h0, 0, '0, '0);
        if (last_rdata !== 64'h1111_2222_3333_4444) $fatal(1, "[DIRECTED] zero-mask write changed data");
        // first/last byte, halfword and word offsets
        dreq(64'h0,       1, 64'h0000_0000_0000_00a5, 8'h01);   // first byte
        dreq(SIZE - 1,    1, 64'h5a00_0000_0000_0000, 8'h80);   // last byte
        dreq(SIZE - 2,    1, 64'h7e3c_0000_0000_0000, 8'hc0);   // last halfword
        dreq(SIZE - 4,    1, 64'h89ab_cdef_0000_0000, 8'hf0);   // last word (32-bit)
        dreq(64'h4,       1, 64'h0bad_f00d_0000_0000, 8'hf0);   // upper word of the first dword
        dreq(64'h0,  0, '0, '0); dreq(SIZE - 1, 0, '0, '0); dreq(SIZE - 8, 0, '0, '0);
        if (masks_seen !== '1) $fatal(1, "[COVER] not all 256 masks written");
        // ---- random ----
        random_on = 1;
        while (n_acc < 4000) begin
            @(posedge clk);
            // cancel an outstanding read whose response is not visible at this edge
            if (n_acc > 2500 && n_cancel == 0 && pending && !pend_wen && !up_bus.rvalid) begin
                @(negedge clk); #2 soft_reset = 1; m_valid = 0; pending = 0; n_cancel++;
                repeat (4) @(posedge clk);
                @(negedge clk); #2 soft_reset = 0;
            end
        end
        random_on = 0;
        while (pending) @(posedge clk);
        @(negedge clk); m_valid = 0; in_fault_phase = 1;
        repeat (5) @(posedge clk);
        if (fault || fault_seen) $fatal(1, "[FAULT] unexpected fault during normal traffic");
        fault_case(SIZE, 1'b1);                         // first word past 64 MiB
        fault_case(SIZE + 64'h1234_5678, 1'b0);         // far out of range
        fault_case(64'hFFFF_FFFF_FFFF_FFF8, 1'b0);      // would wrap below the base if added first
        in_fault_phase = 0;
        dreq(SIZE - 8, 0, '0, '0);                       // normal access works again
        if (n_withdraw == 0 || n_change == 0 || n_cancel != 1 || n_zero_mask == 0)
            $fatal(1, "[COVER] withdraw=%0d change=%0d cancel=%0d zero_mask=%0d", n_withdraw, n_change, n_cancel, n_zero_mask);
        if (n_acc != n_rsp + n_cancel)
            $fatal(1, "[ACCOUNT] accepted=%0d responses=%0d cancelled=%0d", n_acc, n_rsp, n_cancel);
        $display("MEMBUS_SDRAM_ADAPTER_PASS clk=%0d accepted=%0d responses=%0d writes=%0d masks=256 zero_mask=%0d withdraw=%0d change=%0d cancel=%0d words=%0d faults=3 cycles=%0d",
                 CLK_HZ, n_acc, n_rsp, n_w, n_zero_mask, n_withdraw, n_change, n_cancel, word_known.num(), cyc);
        $finish;
    end
    initial begin #4_000_000_000; $fatal(1, "[WATCHDOG] accepted=%0d responses=%0d", n_acc, n_rsp); end
endmodule
