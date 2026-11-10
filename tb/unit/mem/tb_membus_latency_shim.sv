`timescale 1ns/1ps
// Unit TB for tb/model/membus_latency_shim.sv (C3 M1).
// Master model: random requests, legal pre-fire withdraw/change, may assert a
// new request in the cycle of the previous response (R3).
// Downstream model: random ready, response 1..TB_DOWN_MAX cycles after accept,
// byte-masked sparse memory.
// Checks: exact payload downstream, one response per accepted request, latency
// >= 2, no response without an outstanding request, read data = reference,
// ready independent of valid, no handshake/response during reset, refresh
// windows (run length = LEN, start distance = PERIOD), no response emitted
// right after a stalled cycle, reset mid-transaction recovery.
// Negative builds: TB_NEG_SPURIOUS (downstream rvalid while idle -> shim fatal).
module tb_membus_latency_shim;
    localparam int unsigned TB_DOWN_MAX = 6;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst = 0;

    Membus up_bus();
    Membus down_bus();
    membus_latency_shim dut(.clk(clk), .rst(rst), .up(up_bus), .down(down_bus));

    // ---------------- TB RNG (pure next-state function) ----------------
    logic [63:0] tb_rng;
    function automatic logic [63:0] xs(input logic [63:0] s);
        logic [63:0] x;
        x = s; x = x ^ (x << 13); x = x ^ (x >> 7); x = x ^ (x << 17);
        return x;
    endfunction
    function automatic int unsigned rnd(input int unsigned lo, input int unsigned hi);
        tb_rng = xs(tb_rng);
        if (tb_rng == 0) $fatal(1, "TB rng zero");
        return lo + int'(tb_rng % (64'(hi) - 64'(lo) + 64'd1));
    endfunction

    // ---------------- configuration ----------------
    int unsigned n_requests, refresh_period, refresh_len, reset_at, ready_max;
    initial begin
        logic [63:0] seed;
        seed = 64'h2026_1110_5EED_0001;
        void'($value$plusargs("TB_SEED=%d", seed));
        if (seed == 0) $fatal(1, "TB_SEED must be non-zero");
        tb_rng = seed;
        n_requests = 4000;
        void'($value$plusargs("TB_REQUESTS=%d", n_requests));
        ready_max = 3;
        void'($value$plusargs("RAM_SHIM_READY_MAX=%d", ready_max));
        refresh_period = 343; refresh_len = 10;
        void'($value$plusargs("RAM_SHIM_REFRESH_PERIOD=%d", refresh_period));
        void'($value$plusargs("RAM_SHIM_REFRESH_LEN=%d", refresh_len));
        reset_at = n_requests / 2;
    end

    // ---------------- reference state ----------------
    logic [63:0] shadow [logic [63:0]];
    function automatic logic [63:0] mem_read(input logic [63:0] a);
        return shadow.exists(a) ? shadow[a] : {a[31:0] ^ 32'hA5A5_0F0F, ~a[31:0]};
    endfunction
    function automatic logic [63:0] expand(input logic [7:0] m);
        logic [63:0] r;
        for (int b = 0; b < 8; b++) r[b*8 +: 8] = {8{m[b]}};
        return r;
    endfunction

    typedef struct packed {
        logic [63:0] addr; logic wen; logic [63:0] wdata; logic [7:0] wmask;
    } req_t;
    req_t pend_up;        // accepted upstream, waiting for response
    bit   pend_valid;
    longint unsigned pend_time;
    logic [63:0] pend_expected_rdata;
    bit   down_seen;      // pending request already seen downstream

    // downstream model state
    bit   d_busy;
    int unsigned d_wait;
    logic [63:0] d_rdata;

    // stats
    longint unsigned cyc, n_accepted, n_responses, n_writes, n_withdraw, n_change,
                     n_r3, n_frozen_hold, n_resets_mid, n_refresh_runs;
    int unsigned run_len;
    longint unsigned last_run_start;

    // ---------------- master drive (negedge) ----------------
    logic m_valid; logic [63:0] m_addr; logic m_wen; logic [63:0] m_wdata; logic [7:0] m_wmask;
    assign up_bus.valid = m_valid;
    assign up_bus.addr  = m_addr;
    assign up_bus.wen   = m_wen;
    assign up_bus.wdata = m_wdata;
    assign up_bus.wmask = m_wmask;

    task automatic new_payload();
        m_addr  = 64'(rnd(0, 63)) << 3;           // small address set: aliasing
        m_wen   = rnd(0, 99) < 45;
        m_wdata = {32'(rnd(0, 32'hffff_ffff)), 32'(rnd(0, 32'hffff_ffff))};
        m_wmask = 8'(rnd(0, 255));
    endtask

    // ---------------- downstream drive (negedge) ----------------
    logic d_ready, d_rvalid; logic [63:0] d_rdata_out;
    assign down_bus.ready  = d_ready;
    assign down_bus.rvalid = d_rvalid;
    assign down_bus.rdata  = d_rdata_out;

    bit stall_prev;      // dut.refresh_active during the previous cycle
    bit in_reset_phase;

    initial begin
        m_valid = 0; m_addr = 0; m_wen = 0; m_wdata = 0; m_wmask = 0;
        d_ready = 0; d_rvalid = 0; d_rdata_out = 0;
        pend_valid = 0; d_busy = 0; down_seen = 0;
        cyc = 0; n_accepted = 0; n_responses = 0; n_writes = 0; n_withdraw = 0; n_change = 0;
        n_r3 = 0; n_frozen_hold = 0; n_resets_mid = 0; n_refresh_runs = 0; run_len = 0;
        last_run_start = 0; stall_prev = 0; in_reset_phase = 1;
        repeat (3) @(posedge clk);
        // release after the negedge driver and its #1 ready probe (no race)
        @(negedge clk); #2 rst = 1;
        @(posedge clk); #0.001 in_reset_phase = 0;
    end

    // master + downstream drive at negedge
    always @(negedge clk) begin
        if (rst) begin
            bit r0;
            // downstream: response countdown, random ready
            d_rvalid = 0;
            if (d_busy) begin
                if (d_wait == 0) begin d_rvalid = 1; d_rdata_out = d_rdata; d_busy = 0; end
                else d_wait--;
            end
`ifdef TB_NEG_SPURIOUS
            if (n_responses == 20 && !d_busy && dut.state == 2'd0) begin
                d_rvalid = 1; d_rdata_out = '1;
            end
`endif
            d_ready = rnd(0, 99) < 60;

            // master
            r0 = up_bus.ready;
            if (!pend_valid || up_bus.rvalid) begin
                if (m_valid) begin
                    case (rnd(0, 9))
                        0: begin m_valid = 0; n_withdraw++; end
                        1: begin new_payload(); n_change++; end
                        default: ;
                    endcase
                end else if (n_accepted < n_requests && rnd(0, 99) < 70) begin
                    m_valid = 1; new_payload();
                end
            end else begin
                m_valid = 0;
            end
            #1;
            if (up_bus.ready !== r0) $fatal(1, "[READY] up.ready depends on up.valid (cyc=%0d)", cyc);
        end else begin
            m_valid = 0; d_ready = 0; d_rvalid = 0;
        end
    end

    // checks at posedge (sample pre-edge values)
    always @(posedge clk) begin
        cyc++;
        if (!rst) begin
            if (up_bus.ready || down_bus.valid || up_bus.rvalid)
                $fatal(1, "[RESET] handshake/response visible during reset");
        end else begin
            bit stall_now;
            stall_now = dut.refresh_active;

            // refresh window shape (independent of the shim counters)
            if (stall_now) begin
                if (run_len == 0) begin
                    if (n_refresh_runs > 0 && cyc - last_run_start != refresh_period && !in_reset_phase)
                        $fatal(1, "[REFRESH] run start distance %0d != period %0d", cyc - last_run_start, refresh_period);
                    last_run_start = cyc; n_refresh_runs++;
                end
                run_len++;
                if (up_bus.ready) $fatal(1, "[REFRESH] ready during stall");
            end else if (run_len != 0) begin
                if (run_len != refresh_len) $fatal(1, "[REFRESH] run length %0d != %0d", run_len, refresh_len);
                run_len = 0;
            end
            if (up_bus.rvalid && stall_prev) $fatal(1, "[REFRESH] response emitted from a stalled cycle");
            if (stall_now && dut.state == 2'd3) n_frozen_hold++;
            stall_prev = stall_now;

            // upstream response
            if (up_bus.rvalid) begin
                if (!pend_valid) $fatal(1, "[RSP] response without outstanding request");
                if (cyc - pend_time < 2) $fatal(1, "[RSP] latency %0d < 2", cyc - pend_time);
                if (!down_seen) $fatal(1, "[RSP] response before downstream access");
                if (!pend_up.wen && up_bus.rdata !== pend_expected_rdata)
                    $fatal(1, "[RSP] read data %h != expected %h (addr %h)", up_bus.rdata, pend_expected_rdata, pend_up.addr);
                pend_valid = 0; n_responses++;
            end

            // upstream acceptance
            if (up_bus.valid && up_bus.ready) begin
                if (pend_valid) $fatal(1, "[ACC] acceptance while a request is outstanding");
                if (up_bus.rvalid) n_r3++;
                pend_up = '{addr: up_bus.addr, wen: up_bus.wen, wdata: up_bus.wdata, wmask: up_bus.wmask};
                pend_valid = 1; pend_time = cyc; down_seen = 0; n_accepted++;
                if (up_bus.wen) n_writes++;
                pend_expected_rdata = mem_read(up_bus.addr);
            end

            // downstream acceptance: exact payload, one at a time
            if (down_bus.valid && down_bus.ready) begin
                if (!pend_valid || down_seen) $fatal(1, "[DOWN] unexpected downstream request");
                if (d_busy) $fatal(1, "[DOWN] second downstream request while busy");
                if (down_bus.addr !== pend_up.addr || down_bus.wen !== pend_up.wen ||
                    (pend_up.wen && (down_bus.wdata !== pend_up.wdata || down_bus.wmask !== pend_up.wmask)))
                    $fatal(1, "[DOWN] payload mismatch addr %h/%h wen %b/%b", down_bus.addr, pend_up.addr, down_bus.wen, pend_up.wen);
                down_seen = 1;
                d_rdata = mem_read(down_bus.addr);
                if (down_bus.wen)
                    shadow[down_bus.addr] = (mem_read(down_bus.addr) & ~expand(down_bus.wmask)) |
                                            (down_bus.wdata & expand(down_bus.wmask));
                d_busy = 1; d_wait = rnd(0, TB_DOWN_MAX - 1);
            end

            // reset in the middle of a transaction (once)
            if (n_resets_mid == 0 && n_accepted >= reset_at && pend_valid && down_seen) begin
                n_resets_mid++;
                fork begin
                    #2 rst = 0; in_reset_phase = 1;
                    pend_valid = 0; d_busy = 0; down_seen = 0; run_len = 0; n_refresh_runs = 0; stall_prev = 0;
                    repeat (4) @(posedge clk);
                    @(negedge clk); #2 rst = 1;
                    @(posedge clk); #0.001 in_reset_phase = 0;
                end join_none
            end

            if (n_accepted >= n_requests && !pend_valid) begin
                // exact accounting: one pending request is cancelled per mid reset
                if (n_accepted != n_responses + n_resets_mid)
                    $fatal(1, "[ACCOUNT] accepted=%0d responses=%0d resets=%0d", n_accepted, n_responses, n_resets_mid);
                // Pre-fire withdraw/change is only possible when ready can be low
                // while idle (ready gap or refresh stall configured).
                if (((ready_max != 0 || refresh_period != 0) && (n_withdraw == 0 || n_change == 0)) ||
                    n_writes == 0 || n_resets_mid == 0)
                    $fatal(1, "[COVER] withdraw=%0d change=%0d writes=%0d resets=%0d", n_withdraw, n_change, n_writes, n_resets_mid);
                if (refresh_period != 0 && (n_refresh_runs == 0 || n_frozen_hold == 0))
                    $fatal(1, "[COVER] refresh runs=%0d frozen_hold=%0d", n_refresh_runs, n_frozen_hold);
                $display("SHIM_TB_PASS requests=%0d responses=%0d writes=%0d withdraw=%0d change=%0d r3=%0d frozen_hold=%0d refresh_runs=%0d resets=%0d cycles=%0d",
                         n_accepted, n_responses, n_writes, n_withdraw, n_change, n_r3, n_frozen_hold, n_refresh_runs, n_resets_mid, cyc);
                $finish;
            end
        end
    end

    initial begin
        #200_000_000;
        $fatal(1, "[WATCHDOG] accepted=%0d responses=%0d", n_accepted, n_responses);
    end
endmodule
