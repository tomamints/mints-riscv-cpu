`timescale 1ns/1ps
// jtag_block_mailbox + boot_memory_loader against a random-latency RAM model,
// driven by a JTAG-scan model in an unrelated TCK domain. TCK_HALF/CLK_HALF
// select the clock ratio.
module tb_jtag_block_mailbox #(
    parameter real TCK_HALF = 17.0,
    parameter real CLK_HALF = 5.0
);
    localparam int unsigned WORDS = 64;           // BLOCK_WORDS
    localparam int unsigned RAM_BYTES = 8192 * 8; // 8192 words
    localparam logic [63:0] RUN = 64'h4d494e545352554e;

    logic clk = 0, tck = 0;
    always #(CLK_HALF) clk = ~clk;
    logic rst_n = 0;

    // JTAG pins
    logic tdi = 0, cdr = 0, sdr = 0, udr = 0;
    logic [1:0] ir = 0;
    wire tdo;

    // mailbox <-> loader
    logic cv, cr, rv, rr, re, run, cleared, lfault, mf = 0;
    logic [1:0] op;
    logic [63:0] off, data, rd;
    logic [7:0] mask;
    Membus bus();

    jtag_block_mailbox #(.BLOCK_WORDS(WORDS)) mbox (
        .tck(tck), .tdi(tdi), .tdo(tdo), .ir(ir), .cdr(cdr), .sdr(sdr), .udr(udr),
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cv), .cmd_ready(cr), .cmd_op(op), .cmd_offset(off), .cmd_data(data), .cmd_mask(mask),
        .rsp_valid(rv), .rsp_ready(rr), .rsp_error(re), .rsp_data(rd),
        .cpu_run(run), .cleared(cleared), .loader_fault(lfault), .memory_fault(mf));
    boot_memory_loader #(.RAM_BYTES(RAM_BYTES)) loader (
        .clk(clk), .rst_n(rst_n), .cmd_valid(cv), .cmd_ready(cr), .cmd_op(op),
        .cmd_offset(off), .cmd_data(data), .cmd_mask(mask), .rsp_valid(rv), .rsp_ready(rr),
        .rsp_error(re), .rsp_data(rd), .memory_fault(mf), .cpu_run(run), .cleared(cleared),
        .fault(lfault), .memory_bus(bus));

    // RAM model: random ready and response latency, one outstanding request.
    logic [63:0] mem [RAM_BYTES/8];
    logic [63:0] rng = 64'h7a5d1e0b33c0ffee;
    function automatic logic [63:0] rnd();
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng;
    endfunction
    bit pending = 0; int delay_left = 0; logic [63:0] response; int accesses = 0;
    logic ready_q = 0;
    assign bus.ready = ready_q && !pending;
    always @(posedge clk) begin
        bus.rvalid <= 0;
        ready_q <= (rnd() % 4) != 0;
        if (pending) begin
            if (delay_left == 0) begin bus.rvalid <= 1; bus.rdata <= response; pending = 0; end
            else delay_left--;
        end
        if (rst_n && bus.valid && bus.ready) begin
            if (bus.addr >= RAM_BYTES || bus.addr[2:0] != 0) $fatal(1, "invalid bus request %h", bus.addr);
            accesses++;
            if (bus.wen) for (int b = 0; b < 8; b++) if (bus.wmask[b]) mem[bus.addr >> 3][b*8 +: 8] = bus.wdata[b*8 +: 8];
            response = mem[bus.addr >> 3]; pending = 1; delay_left = int'(rnd() % 6);
        end
    end

    // ---------------- JTAG scan model ----------------
    task automatic tck_cycle();
        #(TCK_HALF) tck = 1; #(TCK_HALF) tck = 0;
    endtask
    // One DR scan of n bits through IR=sel. Bits in tx/rx are LSB first.
    task automatic scan(input logic [1:0] sel, input int n, input logic [63:0] tx [], output logic [63:0] rx []);
        rx = new[(n + 63) / 64];
        foreach (rx[i]) rx[i] = 'x;
        ir = sel;
        tck_cycle();                    // Select-DR
        cdr = 1; tck_cycle(); cdr = 0;  // Capture-DR
        sdr = 1;
        for (int i = 0; i < n; i++) begin
            tdi = (i / 64 < tx.size()) ? tx[i / 64][i % 64] : 1'b0;
            rx[i / 64][i % 64] = tdo;   // sampled before the shifting edge
            tck_cycle();
        end
        sdr = 0; tck_cycle();           // Exit1
        udr = 1; tck_cycle(); udr = 0;  // Update-DR
        tck_cycle(); tck_cycle();       // Run-Test/Idle
    endtask
    function automatic logic [63:0] cmd_word(input logic [1:0] o, input int count, input logic [31:0] woff);
        return {16'h4A42, woff, 14'(count), o};
    endfunction
    logic [63:0] none [];
    task automatic status(output logic [63:0] s);
        logic [63:0] rx [];
        scan(2'd0, 64, none, rx); s = rx[0];
        if (s[63:48] != 16'h4A4D || s[31:24] != 8'($clog2(WORDS))) $fatal(1, "bad status %h", s);
    endtask
    task automatic command(input logic [63:0] c, output logic [63:0] s);
        logic [63:0] tx [], rx [];
        int polls = 0;
        tx = new[1]; tx[0] = c;
        scan(2'd1, 64, tx, rx);
        do begin
            status(s); polls++;
            if (polls > 200000) $fatal(1, "command timeout %h", c);
        end while (s[0] != s[1]);
    endtask
    task automatic put_block(input logic [63:0] words []);
        logic [63:0] rx [];
        scan(2'd2, 64 * words.size(), words, rx);
    endtask
    task automatic get_block(input int n, output logic [63:0] words []);
        logic [63:0] tx [];
        scan(2'd2, 64 * n, tx, words);
    endtask
    task automatic expect_result(input logic [63:0] s, input bit err, input int count, input logic [1:0] o,
                                 input bit c, input bit r, input string what);
        if (s[2] !== err || s[47:32] !== 16'(count) || s[9:8] !== o || s[3] !== c || s[4] !== r || s[10] || s[11])
            $fatal(1, "%s: status %h (want err=%0d count=%0d op=%0d cleared=%0d run=%0d)", what, s, err, count, o, c, r);
    endtask

    logic [63:0] s, blk [], back [];
    int acc0;
    initial begin
        for (int i = 0; i < RAM_BYTES / 8; i++) mem[i] = rnd();
        repeat (3) @(posedge clk); rst_n = 1;
        repeat (3) tck_cycle();
        status(s);
        if (s[0] || s[1] || s[3] || s[4]) $fatal(1, "initial status %h", s);

        // WRITE before CLEAR is refused by the loader.
        blk = new[4]; foreach (blk[i]) blk[i] = rnd();
        put_block(blk);
        command(cmd_word(2'd0, 4, 0), s); expect_result(s, 1, 0, 0, 0, 0, "write before clear");

        // Malformed commands: no RAM access.
        acc0 = accesses;
        command({16'h4A43, 32'd0, 14'd1, 2'd0}, s); expect_result(s, 1, 0, 0, 0, 0, "bad magic");
        command(cmd_word(2'd1, 0, 0), s); expect_result(s, 1, 0, 1, 0, 0, "count zero");
        command(cmd_word(2'd1, WORDS + 1, 0), s); expect_result(s, 1, 0, 1, 0, 0, "count too large");
        if (accesses != acc0) $fatal(1, "malformed command accessed RAM");

        // CLEAR writes every word.
        acc0 = accesses;
        command(cmd_word(2'd2, 0, 0), s); expect_result(s, 0, 1, 2, 1, 0, "clear");
        if (accesses - acc0 != RAM_BYTES / 8) $fatal(1, "clear issued %0d accesses", accesses - acc0);
        for (int i = 0; i < RAM_BYTES / 8; i++) if (mem[i] !== 0) $fatal(1, "clear left word %0d", i);

        // Full and partial blocks, read back through the up buffer.
        for (int t = 0; t < 12; t++) begin
            int n, w;
            n = (t == 0) ? WORDS : 1 + int'(rnd() % WORDS);
            w = (t == 1) ? RAM_BYTES / 8 - n : int'(rnd() % (RAM_BYTES / 8 - n + 1));
            blk = new[n]; foreach (blk[i]) blk[i] = rnd();
            put_block(blk);
            command(cmd_word(2'd0, n, w), s); expect_result(s, 0, n, 0, 1, 0, "write block");
            for (int i = 0; i < n; i++) if (mem[w + i] !== blk[i]) $fatal(1, "RAM word %0d", w + i);
            command(cmd_word(2'd1, n, w), s); expect_result(s, 0, n, 1, 1, 0, "read block");
            get_block(n, back);
            for (int i = 0; i < n; i++) if (back[i] !== blk[i]) $fatal(1, "readback word %0d: %h != %h", i, back[i], blk[i]);
        end

        // A block crossing the end of RAM stops at the first refused word.
        blk = new[8]; foreach (blk[i]) blk[i] = rnd();
        put_block(blk);
        command(cmd_word(2'd0, 8, RAM_BYTES / 8 - 3), s); expect_result(s, 1, 3, 0, 1, 0, "write past end");
        for (int i = 0; i < 3; i++) if (mem[RAM_BYTES / 8 - 3 + i] !== blk[i]) $fatal(1, "end word %0d", i);

        // Wrong-length CMD scan and over-long DATA scan are dropped.
        begin
            logic [63:0] tx [], rx [];
            tx = new[1]; tx[0] = cmd_word(2'd2, 0, 0);
            acc0 = accesses;
            scan(2'd1, 63, tx, rx); status(s);
            if (!s[10] || s[0] != s[1]) $fatal(1, "short CMD scan not dropped: %h", s);
            scan(2'd1, 65, tx, rx); status(s);
            if (!s[10] || s[0] != s[1]) $fatal(1, "long CMD scan not dropped: %h", s);
            blk = new[WORDS + 1]; foreach (blk[i]) blk[i] = rnd();
            put_block(blk); status(s);
            if (!s[11]) $fatal(1, "over-long DATA scan not flagged: %h", s);
            tx[0] = cmd_word(2'd0, 1, 0);
            scan(2'd1, 64, tx, rx); status(s);
            if (!s[10] || s[0] != s[1]) $fatal(1, "command accepted after dropped data: %h", s);
            if (accesses != acc0) $fatal(1, "dropped scans accessed RAM");
        end

        // Command and data while busy (CLEAR takes thousands of clk cycles).
        begin
            logic [63:0] tx [], rx [];
            tx = new[1];
            back = new[1]; back[0] = 0; put_block(back);
            tx[0] = cmd_word(2'd2, 0, 0);
            scan(2'd1, 64, tx, rx); status(s);
            if (s[0] == s[1]) $fatal(1, "clear finished too quickly to test busy");
            tx[0] = cmd_word(2'd1, 1, 0);
            scan(2'd1, 64, tx, rx); status(s);
            if (!s[10]) $fatal(1, "command while busy not dropped: %h", s);
            back = new[2]; back[0] = 0; back[1] = 0; put_block(back); status(s);
            if (!s[11]) $fatal(1, "data while busy not flagged: %h", s);
            do status(s); while (s[0] != s[1]);
            if (s[2] || s[9:8] != 2) $fatal(1, "busy clear result %h", s);
        end

        // RELEASE with the wrong word is refused; the right word runs the CPU.
        blk = new[1]; blk[0] = RUN ^ 64'h1;
        put_block(blk);
        command(cmd_word(2'd3, 0, 0), s); expect_result(s, 1, 0, 3, 1, 0, "release wrong word");
        if (run) $fatal(1, "released on wrong word");
        blk[0] = RUN; put_block(blk);
        command(cmd_word(2'd3, 0, 0), s); expect_result(s, 0, 1, 3, 1, 1, "release");
        if (!run) $fatal(1, "cpu_run not set");

        // After release the loader accepts nothing; the mailbox reports, not hangs.
        acc0 = accesses;
        command(cmd_word(2'd1, 1, 0), s); expect_result(s, 1, 0, 1, 1, 1, "command after release");
        if (accesses != acc0) $fatal(1, "access after release");

        $display("JTAG_BLOCK_MAILBOX_PASS tck_half=%0.1f clk_half=%0.1f", TCK_HALF, CLK_HALF);
        $finish;
    end
    initial begin #2s; $fatal(1, "global timeout"); end
endmodule
