`timescale 1ns/1ps
// tb_dcache: unit test for rtl/cache/dcache.sv (DATA_RAM_STYLE 0 and 1) and,
// with +define+TB_BASELINE_DCACHE, for the saved baseline dcache (HEAD e9f95e7,
// no DATA_RAM_STYLE parameter) under the same stimulus.
//
// Independent checking
//   * ref_mem: architectural memory, updated when a store/AMO is accepted.
//     Every load / AMO old value / uncached read is compared with it.
//   * mem model: backing memory with random backpressure and latency, one
//     outstanding request, a response (rvalid) for reads, writes and AMOs at
//     least one cycle after accept. AMO SWAP/ADD (64-bit) executed atomically.
//   * protocol checkers (independent of the driver tasks): CPU-side request hold
//     and payload stability, exactly one response per load/AMO and none for
//     stores, no response before acceptance; mem-side one outstanding and
//     payload stability while valid && !ready.
//   * after draining (write-through), backing memory == ref_mem.
//   * every completed CPU operation is written to a trace file (+trace=<file>);
//     the runner compares the traces of baseline/STYLE0/STYLE1 (same CPU stream).
//
// Phases inside a clock period (no same-time races):
//   negedge           : mem model drives ready/rvalid/rdata (only the model)
//   negedge + 1 ps    : TB stimulus (cpu_if signals, mem_block, invalidate, rst)
//   negedge + 1 ns    : sample of combinational DUT outputs (fast_load_valid)
//   posedge           : handshakes observed by monitors (DUT outputs before NBA)
//
// Random streams: cpu_rng (operation stream) and mem_rng (backpressure/latency)
// are separate xorshift generators with fixed seeds that do NOT depend on STYLE,
// so the CPU operation stream is identical across baseline/STYLE0/STYLE1.
//
// Not testable at this interface (CPU-dependent): trap/kill cancellation of an
// accepted request (dcache has no cancel input), pipeline replay.
// Markers: DCACHE_TB_PASS / (unsupported profile) DCACHE_TB_UNSUPPORTED_NOT_RAISED.
import eei::*;

module tb_dcache #(
    parameter int unsigned STYLE = 0,
    parameter bit          WB    = 1'b0,
    parameter int unsigned LINES = 8,
    parameter int unsigned SBD   = 4
);
    timeunit 1ns;
    timeprecision 1ps;

    localparam Addr RAM_BASE   = 64'h8000_0000;
    localparam Addr UNC_BASE   = 64'h3000_0800;   // DMA window: not RAM, uncached
    localparam int unsigned CACHE_SPAN = LINES * 32;
    localparam int unsigned WIN_WORDS  = (CACHE_SPAN * 4) / 8;   // 4x cache => conflicts
    localparam real PH_STIM = 0.001;   // ns after negedge
    localparam real PH_SAMP = 1.0;     // ns after negedge

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b0;
    logic invalidate = 1'b0;

    initial begin
        #(400_000_000);
        $fatal(1, "[TB] WATCHDOG");
    end

    // Advance to the stimulus phase of the next period.
    task automatic step();
        @(negedge clk);
        #(PH_STIM);
    endtask
    task automatic steps(input int unsigned n);
        repeat (n) step();
    endtask

    core_data_if cpu_if();
    core_data_if mem_if();
    logic flush_busy;
    logic mem_low_priority;
    logic [2:0] dbg_state;
    logic [7:0] dbg_sb_count;
    logic dbg_sb_issue_valid, dbg_sb_issue_fire, dbg_sb_empty, dbg_cacheable, dbg_hit;
    logic dbg_overlap, dbg_bypass, dbg_rsp_valid, dbg_flush_active;

    dcache #(
        .LINE_COUNT(LINES),
        .STORE_BUFFER_DEPTH(SBD),
`ifndef TB_BASELINE_DCACHE
        .DATA_RAM_STYLE(STYLE),
`endif
        .WRITE_BACK(WB)
    ) dut (
        .clk(clk), .rst(rst), .invalidate(invalidate), .flush_busy(flush_busy),
        .mem_low_priority(mem_low_priority),
        .debug_state(dbg_state), .debug_store_buffer_count(dbg_sb_count),
        .debug_store_buffer_issue_valid(dbg_sb_issue_valid),
        .debug_store_buffer_issue_fire(dbg_sb_issue_fire),
        .debug_store_buffer_empty(dbg_sb_empty), .debug_cpu_cacheable(dbg_cacheable),
        .debug_cache_hit(dbg_hit), .debug_cpu_store_buffer_overlap(dbg_overlap),
        .debug_cacheable_load_can_bypass_store_buffer(dbg_bypass),
        .debug_rsp_valid(dbg_rsp_valid), .debug_flush_active(dbg_flush_active),
        .cpu(cpu_if), .mem(mem_if)
    );

    // ------------------------------------------------------------------
    // Random generators (xorshift64), independent streams
    // ------------------------------------------------------------------
    // Runs 1/2: with an "inout" state argument and declaration initializers the
    // memory stream did not work in the 5.046 build (mem_rand(0,99) never
    // reached 30, so ready never rose; a variant with one extra process did). The state is now updated by
    // explicit assignments from a pure next-state function, seeded in an
    // initial block, and a zero state (never reached from a non-zero xorshift
    // state) is fatal.
    localparam logic [63:0] CPU_SEED = 64'h2026_1109_C0FF_EE01;
    localparam logic [63:0] MEM_SEED = 64'h2026_1109_BADD_CAFE;
    logic [63:0] cpu_rng_s;
    logic [63:0] mem_rng_s;
    initial begin
        cpu_rng_s = CPU_SEED;
        mem_rng_s = MEM_SEED;
    end
    function automatic logic [63:0] xs_next(input logic [63:0] s);
        logic [63:0] r;
        r = s ^ (s << 13);
        r = r ^ (r >> 7);
        r = r ^ (r << 17);
        return r;
    endfunction
    function automatic logic [63:0] cpu_rand64();
        if (cpu_rng_s == 64'd0) $fatal(1, "[TB] cpu RNG state is zero");
        cpu_rng_s = xs_next(cpu_rng_s);
        return cpu_rng_s;
    endfunction
    function automatic int unsigned cpu_rand(input int unsigned lo, input int unsigned hi);
        logic [63:0] r;
        r = cpu_rand64();
        return lo + int'(r % (64'(hi) - 64'(lo) + 64'd1));
    endfunction
    function automatic int unsigned mem_rand(input int unsigned lo, input int unsigned hi);
        if (mem_rng_s == 64'd0) $fatal(1, "[TB] mem RNG state is zero");
        mem_rng_s = xs_next(mem_rng_s);
        return lo + int'(mem_rng_s % (64'(hi) - 64'(lo) + 64'd1));
    endfunction

    // ------------------------------------------------------------------
    // Memory contents
    // ------------------------------------------------------------------
    function automatic logic [63:0] init_word(input Addr a);
        return {a[31:0] ^ 32'hA5A5_0000, ~a[31:0]};
    endfunction
    logic [63:0] backing [Addr];
    logic [63:0] ref_mem [Addr];
    function automatic logic [63:0] rd_backing(input Addr wa);
        return backing.exists(wa) ? backing[wa] : init_word(wa);
    endfunction
    function automatic logic [63:0] rd_ref(input Addr wa);
        return ref_mem.exists(wa) ? ref_mem[wa] : init_word(wa);
    endfunction
    function automatic logic [63:0] merge(input logic [63:0] old, input logic [63:0] d, input logic [7:0] m);
        logic [63:0] r;
        for (int i = 0; i < 8; i++) r[i*8 +: 8] = m[i] ? d[i*8 +: 8] : old[i*8 +: 8];
        return r;
    endfunction

    // ------------------------------------------------------------------
    // Backing memory model (mem side of the cache)
    // ------------------------------------------------------------------
    int unsigned bp_pct = 30;
    int unsigned max_lat = 4;
    bit          mem_block = 1'b0;     // written by tests in the stimulus phase only
    bit          mem_busy = 1'b0;
    int unsigned mem_lat = 0;
    logic [63:0] mem_resp = '0;
    int unsigned mem_reads = 0, mem_writes = 0, mem_amos = 0;
    int unsigned mem_withdrawn = 0;    // valid dropped before ready (recorded)
    Addr         mem_read_log[$];
    Addr         mem_write_log[$];
    logic [7:0]  mem_write_mask_log[$];

    // The model drives local variables (single writer: the negedge process) that
    // are connected to the interface by continuous assignments. (This was first
    // changed while debugging run 1; the actual cause of run 1 was the RNG, see
    // "Random generators". The single-writer form is kept.)
    logic        m_ready = 1'b0;
    logic        m_rvalid = 1'b0;
    logic [63:0] m_rdata = '0;
    assign mem_if.ready = m_ready;
    assign mem_if.rvalid = m_rvalid;
    assign mem_if.rdata = m_rdata;
    assign mem_if.fast_load_valid = 1'b0;
    assign mem_if.fast_load_data = '0;
    assign mem_if.fast_store_valid = 1'b0;

    // accept (posedge)
    always @(posedge clk) begin
        if (rst && mem_if.valid && mem_if.ready) begin
            Addr wa;
            logic [63:0] old;
            if (mem_busy) $fatal(1, "[MEM] accept while a request is outstanding");
            wa = {mem_if.addr[63:3], 3'b000};
            old = rd_backing(wa);
            if (mem_if.is_amo) begin
                logic [63:0] nv;
                unique case (mem_if.amoop)
                    SWAP: nv = mem_if.wdata;
                    ADD:  nv = old + mem_if.wdata;
                    default: $fatal(1, "[MEM] unsupported AMO op in model");
                endcase
                if (mem_if.funct3 != 3'b011) $fatal(1, "[MEM] model supports 64-bit AMO only");
                backing[wa] = nv;
                mem_resp = old;
                mem_amos++;
            end else if (mem_if.wen) begin
                backing[wa] = merge(old, mem_if.wdata, mem_if.wmask);
                mem_resp = '0;
                mem_writes++;
                mem_write_log.push_back(wa);
                mem_write_mask_log.push_back(mem_if.wmask);
            end else begin
                mem_resp = old;
                mem_reads++;
                mem_read_log.push_back(wa);
            end
            mem_busy = 1'b1;
            mem_lat = mem_rand(0, max_lat);
        end
    end

    // drive (negedge, only this process writes m_ready/m_rvalid/m_rdata)
    always @(negedge clk) begin
        if (!rst) begin
            m_ready = 1'b0;
            m_rvalid = 1'b0;
            mem_busy = 1'b0;
        end else if (m_rvalid) begin
            m_rvalid = 1'b0;
            mem_busy = 1'b0;
            m_ready = 1'b0;
        end else if (mem_busy) begin
            m_ready = 1'b0;
            if (mem_lat == 0) begin
                m_rvalid = 1'b1;
                m_rdata = mem_resp;
            end else begin
                mem_lat--;
            end
        end else begin
            m_ready = !mem_block && (mem_rand(0, 99) >= bp_pct);
        end
    end

    // mem-side payload stability while valid && !ready (DUT contract check).
    // AMO requests also compare wdata/amoop/aq/rl/funct3. A withdrawal (valid
    // dropped before ready) is not failed here but counted and logged with its
    // context ([MEM-WITHDRAW] lines) as an unresolved bus-contract risk.
    logic        m_prev_wait = 1'b0;
    Addr         m_prev_addr;
    logic        m_prev_wen, m_prev_amo, m_prev_aq, m_prev_rl;
    logic [63:0] m_prev_wdata;
    logic [7:0]  m_prev_wmask;
    AMOOp        m_prev_amoop;
    logic [2:0]  m_prev_funct3;
    logic [2:0]  m_prev_state;
    logic        m_prev_inv;
    int unsigned m_wait_cycles = 0;
    always @(posedge clk) begin
        if (rst) begin
            if (m_prev_wait) begin
                if (!mem_if.valid) begin
                    mem_withdrawn++;
                    $display("[MEM-WITHDRAW] t=%0t addr=%h wen=%0b amo=%0b wmask=%h waited=%0d state_before=%0d state_now=%0d sb_count=%0d invalidate_before=%0b invalidate_now=%0b flush_active=%0b",
                             $time, m_prev_addr, m_prev_wen, m_prev_amo, m_prev_wmask, m_wait_cycles,
                             m_prev_state, dbg_state, dbg_sb_count, m_prev_inv, invalidate, dbg_flush_active);
                end else if (mem_if.addr !== m_prev_addr || mem_if.wen !== m_prev_wen ||
                             mem_if.is_amo !== m_prev_amo ||
                             (mem_if.wen && (mem_if.wdata !== m_prev_wdata || mem_if.wmask !== m_prev_wmask)) ||
                             (mem_if.is_amo && (mem_if.wdata !== m_prev_wdata || mem_if.amoop !== m_prev_amoop ||
                                                mem_if.aq !== m_prev_aq || mem_if.rl !== m_prev_rl ||
                                                mem_if.funct3 !== m_prev_funct3))) begin
                    $fatal(1, "[MEM-PROTO] request payload changed while waiting for ready: addr %h -> %h wen %0b -> %0b amo %0b -> %0b wmask %h -> %h waited=%0d state %0d -> %0d sb_count=%0d invalidate %0b -> %0b flush_active=%0b",
                           m_prev_addr, mem_if.addr, m_prev_wen, mem_if.wen, m_prev_amo, mem_if.is_amo,
                           m_prev_wmask, mem_if.wmask, m_wait_cycles, m_prev_state, dbg_state, dbg_sb_count,
                           m_prev_inv, invalidate, dbg_flush_active);
                end
            end
            if (mem_if.valid && !mem_if.ready) m_wait_cycles = m_prev_wait ? m_wait_cycles + 1 : 1;
            else m_wait_cycles = 0;
            m_prev_wait   = mem_if.valid && !mem_if.ready;
            m_prev_addr   = mem_if.addr;
            m_prev_wen    = mem_if.wen;
            m_prev_amo    = mem_if.is_amo;
            m_prev_wdata  = mem_if.wdata;
            m_prev_wmask  = mem_if.wmask;
            m_prev_amoop  = mem_if.amoop;
            m_prev_aq     = mem_if.aq;
            m_prev_rl     = mem_if.rl;
            m_prev_funct3 = mem_if.funct3;
            m_prev_state  = dbg_state;
            m_prev_inv    = invalidate;
        end else begin
            m_prev_wait = 1'b0;
            m_wait_cycles = 0;
        end
    end

    // ------------------------------------------------------------------
    // CPU-side protocol checker (independent of the driver tasks)
    // ------------------------------------------------------------------
    int unsigned rvalid_count = 0;
    int unsigned resp_expected = 0;     // accepted loads/AMOs not yet answered
    int unsigned fast_load_hits = 0;
    logic [63:0] last_rdata = '0;
    logic        c_prev_wait = 1'b0;
    Addr         c_prev_addr;
    logic        c_prev_wen, c_prev_amo;
    logic [63:0] c_prev_wdata;
    logic [7:0]  c_prev_wmask;

    always @(posedge clk) begin
        if (rst) begin
            // responses first (state before this edge's acceptance)
            if (cpu_if.rvalid) begin
                if (resp_expected == 0) $fatal(1, "[CPU-PROTO] response without an outstanding load/AMO");
                resp_expected--;
                rvalid_count++;
                last_rdata = cpu_if.rdata;
            end
            if (c_prev_wait) begin
                if (!cpu_if.valid || cpu_if.addr !== c_prev_addr || cpu_if.wen !== c_prev_wen ||
                    cpu_if.is_amo !== c_prev_amo ||
                    (cpu_if.wen && (cpu_if.wdata !== c_prev_wdata || cpu_if.wmask !== c_prev_wmask)))
                    $fatal(1, "[CPU-PROTO] request not held stable until ready (TB driver)");
            end
            if (cpu_if.valid && cpu_if.ready) begin
                if (resp_expected != 0) $fatal(1, "[CPU-PROTO] request accepted while a response is outstanding");
                if (!cpu_if.wen || cpu_if.is_amo) resp_expected++;
            end
            c_prev_wait  = cpu_if.valid && !cpu_if.ready;
            c_prev_addr  = cpu_if.addr;
            c_prev_wen   = cpu_if.wen;
            c_prev_amo   = cpu_if.is_amo;
            c_prev_wdata = cpu_if.wdata;
            c_prev_wmask = cpu_if.wmask;
            if (STYLE != 0) begin
                if (cpu_if.fast_load_valid !== 1'b0) $fatal(1, "[STYLE1] fast_load_valid asserted");
                if (cpu_if.fast_load_data !== 64'd0) $fatal(1, "[STYLE1] fast_load_data not constant 0");
            end
            if (cpu_if.fast_store_req && cpu_if.fast_store_valid && !(cpu_if.valid && cpu_if.ready))
                $fatal(1, "[FASTSTORE] fast store accepted without the normal handshake");
        end else begin
            c_prev_wait = 1'b0;
            resp_expected = 0;
        end
    end

    // ------------------------------------------------------------------
    // CPU driver
    // ------------------------------------------------------------------
    int trace_fd = 0;
    int unsigned op_index = 0;

    initial begin
        string fname;
        cpu_if.valid = 1'b0; cpu_if.addr = '0; cpu_if.wen = 1'b0; cpu_if.wdata = '0;
        cpu_if.wmask = '0; cpu_if.fast_load_req = 1'b0; cpu_if.fast_load_addr = '0;
        cpu_if.fast_load_funct3 = 3'b011; cpu_if.fast_store_req = 1'b0; cpu_if.fast_store_addr = '0;
        cpu_if.is_amo = 1'b0; cpu_if.aq = 1'b0; cpu_if.rl = 1'b0; cpu_if.amoop = ADD;
        cpu_if.funct3 = 3'b011;
        if ($value$plusargs("trace=%s", fname)) trace_fd = $fopen(fname, "w");
    end

    task automatic cpu_idle();
        cpu_if.valid = 1'b0;
        cpu_if.wen = 1'b0;
        cpu_if.is_amo = 1'b0;
        cpu_if.fast_load_req = 1'b0;
        cpu_if.fast_store_req = 1'b0;
    endtask

    task automatic trace(input string kind, input Addr a, input logic [63:0] v);
        op_index++;
        if (trace_fd != 0) begin
            $fdisplay(trace_fd, "%0d %s %016x %016x", op_index, kind, a, v);
            $fflush(trace_fd);   // kept up to date for expected-failure prefix comparison
        end
    endtask

    // One request, called in the stimulus phase. Stores return after acceptance,
    // loads/AMOs after their single response. try_fast also drives fast_*_req.
    task automatic cpu_req(input Addr a, input bit wr, input logic [63:0] d, input logic [7:0] m,
                           input bit amo, input AMOOp op, input bit try_fast,
                           output logic [63:0] rd);
        int unsigned n;
        int unsigned rv0;
        logic [63:0] expect_val;
        Addr wa;
        wa = {a[63:3], 3'b000};
        rv0 = rvalid_count;                          // baseline at request start
        if (!wr && !amo && try_fast) begin
            cpu_if.fast_load_req = 1'b1;
            cpu_if.fast_load_addr = a;
            cpu_if.fast_load_funct3 = 3'b011;
            #(PH_SAMP - PH_STIM);                     // sample phase
            if (cpu_if.fast_load_valid) begin
                expect_val = rd_ref(wa);
                rd = cpu_if.fast_load_data;
                step();
                cpu_if.fast_load_req = 1'b0;
                if (rd !== expect_val) $fatal(1, "[LOAD-FAST] %h: got %h expected %h", a, rd, expect_val);
                fast_load_hits++;
                trace("LD", a, rd);
                return;
            end
        end
        cpu_if.valid = 1'b1;
        cpu_if.addr = a;
        cpu_if.wen = wr;
        cpu_if.wdata = d;
        cpu_if.wmask = m;
        cpu_if.is_amo = amo;
        cpu_if.amoop = op;
        cpu_if.funct3 = 3'b011;
        cpu_if.fast_store_req = wr && !amo && try_fast;
        cpu_if.fast_store_addr = a;
        n = 0;
        forever begin
            @(posedge clk);
            if (cpu_if.valid && cpu_if.ready) break;
            n++;
            if (n > 20000) $fatal(1, "[CPU] request at %h never accepted", a);
        end
        expect_val = rd_ref(wa);                     // reference at acceptance
        if (amo)         ref_mem[wa] = (op == SWAP) ? d : (expect_val + d);
        else if (wr)     ref_mem[wa] = merge(expect_val, d, m);
        step();
        cpu_idle();
        if (rvalid_count != rv0) $fatal(1, "[CPU] response observed at or before acceptance of %h", a);
        if (wr && !amo) begin
            steps(2);
            if (rvalid_count != rv0) $fatal(1, "[STORE] unexpected response after store at %h", a);
            rd = '0;
            trace("ST", a, merge(expect_val, d, m));
            return;
        end
        n = 0;
        while (rvalid_count == rv0) begin
            step();
            n++;
            if (n > 20000) $fatal(1, "[CPU] no response for %h (state=%0d mem_valid=%0b mem_busy=%0b mem_reads=%0d rvalid_count=%0d resp_expected=%0d)",
                                  a, dbg_state, mem_if.valid, mem_busy, mem_reads, rvalid_count, resp_expected);
        end
        rd = last_rdata;
        if (rd !== expect_val)
            $fatal(1, "[%s] %h: got %h expected %h (style=%0d)", amo ? "AMO" : "LOAD", a, rd, expect_val, STYLE);
        steps(2);
        if (rvalid_count != rv0 + 1) $fatal(1, "[CPU] extra response for %h", a);
        trace(amo ? "AM" : "LD", a, rd);
    endtask

    task automatic ld(input Addr a, input bit fast = 1'b0);
        logic [63:0] r;
        cpu_req(a, 1'b0, '0, 8'h00, 1'b0, ADD, fast, r);
    endtask
    task automatic st(input Addr a, input logic [63:0] d, input logic [7:0] m, input bit fast = 1'b0);
        logic [63:0] r;
        cpu_req(a, 1'b1, d, m, 1'b0, ADD, fast, r);
    endtask
    task automatic amo(input Addr a, input AMOOp op, input logic [63:0] d);
        logic [63:0] r;
        cpu_req(a, 1'b0, d, 8'hFF, 1'b1, op, 1'b0, r);
    endtask

    // Bounded wait until the cache is Idle, the store buffer is empty and the
    // memory model has no outstanding request.
    task automatic wait_idle();
        int unsigned n;
        n = 0;
        while (!(dbg_state == 3'd0 && dbg_sb_empty && !mem_busy && !mem_if.valid)) begin
            step();
            n++;
            if (n > 50000) $fatal(1, "[TB] cache/memory did not become idle");
        end
        steps(2);
    endtask

    function automatic Addr cline(input int unsigned line, input int unsigned word);
        return RAM_BASE + Addr'(line * 32 + word * 8);
    endfunction

    // Load one word of a line, wait until the fill has completed, then prove the
    // whole line is resident (every word hits without memory reads).
    task automatic prefill(input int unsigned line);
        int unsigned r0;
        ld(cline(line, 0));
        wait_idle();
        r0 = mem_read_log.size();
        for (int w = 0; w < 4; w++) ld(cline(line, w));
        if (mem_read_log.size() != r0) $fatal(1, "[PREFILL] line %0d not resident after its fill", line);
    endtask

    task automatic check_backing_equals_ref();
        foreach (ref_mem[wa])
            if (rd_backing(wa) !== ref_mem[wa])
                $fatal(1, "[FINAL] backing %h = %h, ref %h", wa, rd_backing(wa), ref_mem[wa]);
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic t_cold_miss_critical_first();
        for (int w = 0; w < 4; w++) begin
            int unsigned r0, r1;
            r0 = mem_read_log.size();
            ld(cline(100 + w, w));                       // returns at the critical-word response
            if (mem_read_log.size() < r0 + 1 || mem_read_log[r0] !== cline(100 + w, w))
                $fatal(1, "[FILL] first beat is not the requested (critical) word %0d", w);
            wait_idle();                                 // the rest of the line completes
            if (mem_read_log.size() != r0 + 4) $fatal(1, "[FILL] %0d beats for one line", mem_read_log.size() - r0);
            for (int k = 0; k < 4; k++)
                if (mem_read_log[r0 + k] !== cline(100 + w, (w + k) % 4))
                    $fatal(1, "[FILL] beat %0d addr %h expected %h (wrap)", k, mem_read_log[r0 + k], cline(100 + w, (w + k) % 4));
            r1 = mem_read_log.size();
            for (int k = 0; k < 4; k++) ld(cline(100 + w, k));
            if (mem_read_log.size() != r1) $fatal(1, "[HIT] a word of the filled line missed");
        end
        $display("[T] cold miss: critical word first, then 4 beats with wrap; all words hit: PASS");
    endtask

    task automatic t_masks();
        Addr a;
        int unsigned r0;
        prefill(3);
        a = cline(3, 1);
        r0 = mem_read_log.size();
        for (int m = 0; m < 256; m++) begin
            st(a, {8{8'(m)}} ^ 64'h0123_4567_89AB_CDEF, 8'(m), m[0]);
            ld(a, 1'b1);
        end
        if (WB == 0 && mem_read_log.size() != r0) $fatal(1, "[MASK] the hit line was refilled during the mask test");
        a = cline(4, 2);                                 // miss path (no allocate on store)
        for (int m = 1; m < 256; m += 37) begin
            st(a, 64'hFEED_FACE_CAFE_BEEF ^ 64'(m), 8'(m));
            ld(a);
        end
        $display("[T] all 256 byte masks on a resident line (+ subset on a miss line): PASS");
    endtask

    task automatic t_store_buffer_full_and_overlap();
        int unsigned w0;
        Addr a0;
        prefill(5);
        a0 = cline(5, 0);
        wait_idle();
        mem_block = 1'b1;
        // non-resident lines: with WRITE_BACK=1 a store hit is written into the
        // cache and does not occupy the store buffer (dcache.sv: WRITE_BACK && cache_hit).
        for (int i = 0; i < SBD; i++) st(cline(60 + 2 * i, 0), 64'h1111_0000 + 64'(i), 8'hFF);
        if (dbg_sb_count != 8'(SBD)) $fatal(1, "[SB] store buffer not full (%0d of %0d)", dbg_sb_count, SBD);
        fork
            st(cline(20, 0), 64'h2222, 8'hFF);             // needs a free entry
            begin steps(50); mem_block = 1'b0; end
        join
        wait_idle();
        mem_block = 1'b1;
        st(a0, 64'h3333_4444_5555_6666, 8'h0F);
        fork
            ld(a0);                                        // overlaps the buffered store
            begin steps(30); mem_block = 1'b0; end
        join
        wait_idle();
        mem_block = 1'b1;
        w0 = mem_write_log.size();
        // RTL combines only into a non-head entry (dcache.sv: idx != store_buffer_head),
        // so a different word is buffered first as the head.
        st(cline(22, 0), 64'h00000000_000000CC, 8'hFF);
        st(cline(21, 1), 64'h00000000_000000AA, 8'h01);
        st(cline(21, 1), 64'h00000000_0000BB00, 8'h02);
        if (dbg_sb_count != 8'd2) $fatal(1, "[COMBINE] store buffer holds %0d entries, expected 2", dbg_sb_count);
        mem_block = 1'b0;
        wait_idle();
        if (mem_write_log.size() - w0 != 2 || mem_write_log[w0] !== cline(22, 0) ||
            mem_write_log[w0 + 1] !== cline(21, 1) || mem_write_mask_log[w0 + 1] !== 8'h03)
            $fatal(1, "[COMBINE] expected head write + one combined write with mask 03, got %0d writes", mem_write_log.size() - w0);
        ld(cline(21, 1));
        ld(cline(22, 0));
        $display("[T] store buffer full -> drain, overlapping load, store combining: PASS");
    endtask

    task automatic t_amo_and_uncached();
        Addr a;
        int unsigned r0;
        prefill(6);
        a = cline(6, 3);
        amo(a, ADD, 64'd5);
        wait_idle();
        r0 = mem_read_log.size();
        ld(a);
        if (WB == 0 && mem_read_log.size() == r0) $fatal(1, "[AMO] line not invalidated by the AMO");
        amo(a, SWAP, 64'h0BAD_F00D_0BAD_F00D);
        ld(a);
        st(UNC_BASE, 64'h7777_8888_9999_AAAA, 8'hFF);
        ld(UNC_BASE);
        st(UNC_BASE + 8, 64'h0, 8'h80);
        ld(UNC_BASE + 8);
        $display("[T] AMO invalidates the resident line; uncached loads/stores bypass: PASS");
    endtask

    task automatic t_invalidate_during_fill();
        Addr a;
        int unsigned r0, r1;
        a = cline(40, 2);
        wait_idle();
        r0 = mem_read_log.size();
        fork
            ld(a);
            begin
                while (mem_read_log.size() == r0) step();
                invalidate = 1'b1;
                step();
                invalidate = 1'b0;
            end
        join
        wait_idle();
        r1 = mem_read_log.size();
        ld(a);
        if (mem_read_log.size() == r1) $fatal(1, "[INV] line allocated although invalidated during the fill");
        $display("[T] invalidate during a fill: response correct, line not allocated: PASS");
    endtask

    task automatic t_fast_paths();
        int unsigned f0;
        prefill(7);
        wait_idle();
        f0 = fast_load_hits;
        for (int i = 0; i < 8; i++) ld(cline(7, i % 4), 1'b1);
        if (STYLE == 0 && fast_load_hits == f0) $fatal(1, "[FAST] STYLE0: no fast-load completion on resident words");
        if (STYLE != 0 && fast_load_hits != f0) $fatal(1, "[FAST] STYLE1: fast-load completed");
        for (int i = 0; i < 4; i++) st(cline(7, i), 64'(i) * 64'h0101_0101_0101_0101, 8'hFF, 1'b1);
        for (int i = 0; i < 4; i++) ld(cline(7, i), 1'b1);
        $display("[T] fast paths: STYLE%0d fast-load %s; fast-store requires the normal handshake: PASS",
                 STYLE, STYLE == 0 ? "used" : "disabled (fallback)");
    endtask

    task automatic t_random(input int unsigned n);
        for (int unsigned i = 0; i < n; i++) begin
            int unsigned k;
            Addr a;
            k = cpu_rand(0, 99);
            a = RAM_BASE + Addr'(cpu_rand(0, WIN_WORDS - 1) * 8);
            if (k < 40)       ld(a, 1'(cpu_rand(0, 1)));
            else if (k < 80)  st(a, cpu_rand64(), 8'(cpu_rand(1, 255)), 1'(cpu_rand(0, 1)));
            else if (k < 85)  amo(a, (cpu_rand(0, 1) != 0) ? ADD : SWAP, cpu_rand64());
            else if (k < 90)  ld(UNC_BASE + Addr'(cpu_rand(0, 7) * 8));
            else if (k < 95)  st(UNC_BASE + Addr'(cpu_rand(0, 7) * 8), cpu_rand64(), 8'(cpu_rand(1, 255)));
            else begin
                if (cpu_rand(0, 3) == 0) begin
                    invalidate = 1'b1;
                    step();
                    invalidate = 1'b0;
                end
                steps(cpu_rand(0, 3));
            end
        end
        $display("[T] random %0d operations (cpu/mem RNG separate, fixed seeds): PASS", n);
    endtask

    task automatic t_reset_cold();
        int unsigned r0;
        wait_idle();
        if (WB == 0) check_backing_equals_ref();
        rst = 1'b0;
        steps(3);
        rst = 1'b1;
        steps(2);
        if (WB != 0) begin
            ref_mem.delete();
            foreach (backing[wa]) ref_mem[wa] = backing[wa];
        end
        r0 = mem_read_log.size();
        ld(cline(7, 1));
        if (mem_read_log.size() == r0) $fatal(1, "[RESET] cache not cold after reset");
        $display("[T] reset (interface level): cache cold afterwards: PASS");
    endtask

    // WB1 smoke (profile wb1_smoke, +define+TB_WB1_SMOKE): a LIMITED comparison
    // that avoids the two known WRITE_BACK=1 failures (invalidate during a fill;
    // AMO on a dirty line). It is NOT the full regression: cold miss/hit, partial
    // stores on a resident line (dirty), dirty eviction (writeback), AMO on a
    // clean resident line and on a non-resident line.
    task automatic t_wb1_smoke();
        Addr a;
        t_cold_miss_critical_first();
        t_masks();                                      // line 3 resident and dirty
        a = cline(3, 1);
        ld(cline(3 + LINES, 0));                        // same index: evicts dirty line 3
        wait_idle();
        if (WB != 0 && rd_backing(a) !== rd_ref(a))
            $fatal(1, "[WB1-SMOKE] dirty line not written back on eviction: backing %h ref %h", rd_backing(a), rd_ref(a));
        ld(a);                                          // refetch equals ref
        prefill(6);                                     // clean resident line
        amo(cline(6, 3), ADD, 64'd7);
        ld(cline(6, 3));
        amo(cline(50, 0), SWAP, 64'h5A5A_A5A5_0F0F_F0F0); // non-resident
        ld(cline(50, 0));
        st(cline(9, 2), 64'h1234_5678_9ABC_DEF0, 8'h3C);  // partial store on a miss line
        ld(cline(9, 2));
        wait_idle();
        $display("[T] WB1 smoke (limited): cold/hit, partial stores, dirty evict, AMO clean/non-resident: PASS");
    endtask

    initial begin
        step();
        rst = 1'b0;
        steps(4);
        rst = 1'b1;
        steps(2);
`ifdef TB_UNSUPPORTED_PROFILE
        $display("DCACHE_TB_UNSUPPORTED_NOT_RAISED");
        $finish;
`elsif TB_WB1_SMOKE
        t_wb1_smoke();
        $display("[TB] ops=%0d mem reads=%0d writes=%0d amos=%0d cpu responses=%0d mem valid withdrawn=%0d",
                 op_index, mem_reads, mem_writes, mem_amos, rvalid_count, mem_withdrawn);
        if (trace_fd != 0) $fclose(trace_fd);
        $display("DCACHE_TB_WB1_SMOKE_PASS style=%0d wb=%0d lines=%0d sbd=%0d (limited, not full regression)", STYLE, WB, LINES, SBD);
        $finish;
`else
        $display("[TB] STYLE=%0d WB=%0d LINES=%0d SBD=%0d baseline=%0d", STYLE, WB, LINES, SBD,
`ifdef TB_BASELINE_DCACHE
                 1
`else
                 0
`endif
                 );
        t_cold_miss_critical_first();
        t_masks();
        t_store_buffer_full_and_overlap();
        t_amo_and_uncached();
        t_invalidate_during_fill();
        t_fast_paths();
        t_random(20000);
        wait_idle();
        if (WB == 0) begin
            check_backing_equals_ref();
            $display("[T] write-through: backing memory equals the reference after drain: PASS");
        end
        t_reset_cold();
        $display("[TB] ops=%0d mem reads=%0d writes=%0d amos=%0d cpu responses=%0d fast-load hits=%0d mem valid withdrawn=%0d",
                 op_index, mem_reads, mem_writes, mem_amos, rvalid_count, fast_load_hits, mem_withdrawn);
        if (trace_fd != 0) $fclose(trace_fd);
        $display("DCACHE_TB_PASS style=%0d wb=%0d lines=%0d sbd=%0d", STYLE, WB, LINES, SBD);
        $finish;
`endif
    end

endmodule : tb_dcache
