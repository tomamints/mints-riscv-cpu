// Simulation-only latency injector for the RAM Membus (C3 milestone M1).
// Instantiated by src/top.sv only when SVCPU_RAM_LATENCY_SHIM is defined.
//
// Contract kept towards the upstream master (C3 R1-R3):
//   - a request is captured only at up.valid && up.ready; ready does not depend
//     on valid; nothing happens before the handshake;
//   - one outstanding request; the payload is latched and replayed downstream;
//   - exactly one response per request (reads and writes), at least 2 cycles
//     after acceptance; a new acceptance may coincide with that response.
// Delays (fixed-seed xorshift64, configurable with plusargs):
//   +RAM_SHIM_SEED=<n>            seed, non-zero (default 1)
//   +RAM_SHIM_READY_MAX=<n>       ready-low gap 0..n cycles after reset/response (default 3)
//   +RAM_SHIM_RSP_MIN=<n>         extra response delay min (default 0)
//   +RAM_SHIM_RSP_MAX=<n>         extra response delay max (default 48)
//   +RAM_SHIM_REFRESH_PERIOD=<n>  refresh-like stall every n cycles, 0 = off (default 343)
//   +RAM_SHIM_REFRESH_LEN=<n>     stall length in cycles (default 10)
// Optional trace (off by default; draws no random numbers):
//   +RAM_SHIM_TRACE0_LO=<hex> +RAM_SHIM_TRACE0_HI=<hex>  (byte offsets, inclusive)
//   +RAM_SHIM_TRACE1_LO=<hex> +RAM_SHIM_TRACE1_HI=<hex>
// prints one line per event for requests whose 8-byte word overlaps a window:
//   RAM_SHIM_TRACE cyc=<n> ev=ACC|ISS|DRSP|URSP wen=<b> addr=<offset> wdata=<h> wmask=<h> [rdata=<h>]
// ACC = upstream accept, ISS = downstream issue (down fire), DRSP = downstream
// response (write performed at RAM), URSP = upstream response.
// A refresh stall blocks acceptance and freezes the whole response hold
// (countdown and emission). A request already issued downstream is not
// cancelled by a stall: this is a latency injector, not a cycle-accurate
// SDRAM model. All delay plusargs must be <= 1000000.
// No package import: the Makefile adds this file before core.f.
module membus_latency_shim #(
    parameter int ADDR_WIDTH = 64,
    parameter int DATA_WIDTH = 64
) (
    input logic clk,
    input logic rst,
    Membus.slave  up,
    Membus.master down
);
    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_WAIT, S_HOLD} state_t;
    state_t state;

    logic [ADDR_WIDTH-1:0]     addr_q;
    logic                      wen_q;
    logic [DATA_WIDTH-1:0]     wdata_q;
    logic [(DATA_WIDTH/8)-1:0] wmask_q;
    logic [DATA_WIDTH-1:0]     rdata_q;
    logic                             rvalid_q;

    int unsigned gap_cnt, rsp_cnt, refresh_cnt, refresh_left;
    logic [63:0] rng;

    localparam int unsigned CFG_MAX = 1000000;
    int unsigned cfg_seed, cfg_ready_max, cfg_rsp_min, cfg_rsp_max;
    int unsigned cfg_refresh_period, cfg_refresh_len;

    longint unsigned stat_requests, stat_writes, stat_max_latency, stat_refresh_stalls;
    longint unsigned latency_now;

    // trace configuration and a free-running cycle counter (no RNG use)
    bit trace_en0, trace_en1;
    logic [63:0] trace0_lo, trace0_hi, trace1_lo, trace1_hi;
    longint unsigned trace_cyc;
    function automatic bit traced(input logic [ADDR_WIDTH-1:0] a);
        logic [63:0] w;
        w = 64'(a) & ~64'h7;
        return (trace_en0 && w + 7 >= trace0_lo && w <= trace0_hi) ||
               (trace_en1 && w + 7 >= trace1_lo && w <= trace1_hi);
    endfunction

    initial begin
        cfg_seed = 1;
        cfg_ready_max = 3;
        cfg_rsp_min = 0;
        cfg_rsp_max = 48;
        cfg_refresh_period = 343;
        cfg_refresh_len = 10;
        void'($value$plusargs("RAM_SHIM_SEED=%d", cfg_seed));
        void'($value$plusargs("RAM_SHIM_READY_MAX=%d", cfg_ready_max));
        void'($value$plusargs("RAM_SHIM_RSP_MIN=%d", cfg_rsp_min));
        void'($value$plusargs("RAM_SHIM_RSP_MAX=%d", cfg_rsp_max));
        void'($value$plusargs("RAM_SHIM_REFRESH_PERIOD=%d", cfg_refresh_period));
        void'($value$plusargs("RAM_SHIM_REFRESH_LEN=%d", cfg_refresh_len));
        if (DATA_WIDTH <= 0 || DATA_WIDTH % 8 != 0 || ADDR_WIDTH <= 0)
            $fatal(1, "RAM_SHIM bad width parameters");
        if (cfg_ready_max > CFG_MAX || cfg_rsp_min > CFG_MAX || cfg_rsp_max > CFG_MAX ||
            cfg_refresh_period > CFG_MAX || cfg_refresh_len > CFG_MAX)
            $fatal(1, "RAM_SHIM delay plusarg out of range (max %0d; negative values are rejected)", CFG_MAX);
        if ($bits(up.addr) != ADDR_WIDTH || $bits(up.wdata) != DATA_WIDTH ||
            $bits(down.addr) != ADDR_WIDTH || $bits(down.wdata) != DATA_WIDTH)
            $fatal(1, "RAM_SHIM width mismatch");
        trace_en0 = $value$plusargs("RAM_SHIM_TRACE0_LO=%h", trace0_lo) != 0;
        trace_en0 = ($value$plusargs("RAM_SHIM_TRACE0_HI=%h", trace0_hi) != 0) && trace_en0;
        trace_en1 = $value$plusargs("RAM_SHIM_TRACE1_LO=%h", trace1_lo) != 0;
        trace_en1 = ($value$plusargs("RAM_SHIM_TRACE1_HI=%h", trace1_hi) != 0) && trace_en1;
        if ((trace_en0 && trace0_lo > trace0_hi) || (trace_en1 && trace1_lo > trace1_hi))
            $fatal(1, "RAM_SHIM trace window LO > HI");
        if (trace_en0) $display("RAM_SHIM trace0 %h..%h", trace0_lo, trace0_hi);
        if (trace_en1) $display("RAM_SHIM trace1 %h..%h", trace1_lo, trace1_hi);
        if (cfg_seed == 0) $fatal(1, "RAM_SHIM_SEED must be non-zero");
        if (cfg_rsp_min > cfg_rsp_max) $fatal(1, "RAM_SHIM_RSP_MIN > RAM_SHIM_RSP_MAX");
        if (cfg_refresh_period != 0 && cfg_refresh_len >= cfg_refresh_period)
            $fatal(1, "RAM_SHIM_REFRESH_LEN must be < RAM_SHIM_REFRESH_PERIOD");
        $display("RAM_SHIM seed=%0d ready_max=%0d rsp=%0d..%0d refresh=%0d/%0d",
                 cfg_seed, cfg_ready_max, cfg_rsp_min, cfg_rsp_max,
                 cfg_refresh_period, cfg_refresh_len);
    end

    // Pure next-state function (no inout state; see the C1 TB RNG issue).
    function automatic logic [63:0] xs_next(input logic [63:0] s);
        logic [63:0] x;
        x = s;
        x = x ^ (x << 13);
        x = x ^ (x >> 7);
        x = x ^ (x << 17);
        return x;
    endfunction

    // 64-bit span: hi - lo + 1 cannot wrap (bounds are <= CFG_MAX).
    function automatic int unsigned pick(input logic [63:0] s, input int unsigned lo, input int unsigned hi);
        logic [63:0] span;
        span = 64'(hi) - 64'(lo) + 64'd1;
        return int'(64'(lo) + (s % span));
    endfunction

    wire refresh_active = refresh_left != 0;

    // Upstream: ready depends only on state, never on valid.
    // No observable handshake while the asynchronous reset is asserted.
    assign up.ready  = rst && (state == S_IDLE) && (gap_cnt == 0) && !refresh_active;
    assign up.rvalid = rvalid_q;
    assign up.rdata  = rdata_q;

    // Downstream: replay the latched payload until accepted.
    assign down.valid = rst && (state == S_ISSUE);
    assign down.addr  = addr_q;
    assign down.wen   = wen_q;
    assign down.wdata = wdata_q;
    assign down.wmask = wmask_q;

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            state        <= S_IDLE;
            addr_q       <= '0;
            wen_q        <= 1'b0;
            wdata_q      <= '0;
            wmask_q      <= '0;
            rdata_q      <= '0;
            rvalid_q     <= 1'b0;
            gap_cnt      <= 0;
            rsp_cnt      <= 0;
            refresh_cnt  <= 0;
            refresh_left <= 0;
            rng          <= 64'(cfg_seed);
            latency_now  <= 0;
            stat_requests       <= 0;
            stat_writes         <= 0;
            stat_max_latency    <= 0;
            stat_refresh_stalls <= 0;
        end else begin
            rvalid_q <= 1'b0;

            // refresh-like stall generator
            if (cfg_refresh_period != 0) begin
                if (refresh_cnt + 1 >= cfg_refresh_period) begin
                    refresh_cnt  <= 0;
                    refresh_left <= cfg_refresh_len;
                    stat_refresh_stalls <= stat_refresh_stalls + 1;
                end else begin
                    refresh_cnt <= refresh_cnt + 1;
                    if (refresh_left != 0) refresh_left <= refresh_left - 1;
                end
            end

            if (gap_cnt != 0) gap_cnt <= gap_cnt - 1;
            if (state != S_IDLE) latency_now <= latency_now + 1;

            unique case (state)
                S_IDLE: if (up.valid && up.ready) begin
                    addr_q  <= up.addr;
                    wen_q   <= up.wen;
                    wdata_q <= up.wdata;
                    wmask_q <= up.wmask;
                    latency_now <= 1;
                    stat_requests <= stat_requests + 1;
                    if (up.wen) stat_writes <= stat_writes + 1;
                    state <= S_ISSUE;
                end
                S_ISSUE: if (down.ready) state <= S_WAIT;
                S_WAIT: if (down.rvalid) begin
                    rdata_q <= down.rdata;
                    rng     <= xs_next(rng);
                    rsp_cnt <= pick(rng, cfg_rsp_min, cfg_rsp_max);
                    state   <= S_HOLD;
                end
                // Whole hold frozen while a stall is active (pre-edge value).
                S_HOLD: if (!refresh_active) begin
                    if (rsp_cnt == 0) begin
                        rvalid_q <= 1'b1;
                        rng      <= xs_next(rng);
                        gap_cnt  <= pick(rng, 0, cfg_ready_max);
                        if (latency_now > stat_max_latency) stat_max_latency <= latency_now;
                        state    <= S_IDLE;
                    end else begin
                        rsp_cnt <= rsp_cnt - 1;
                    end
                end
                default: state <= S_IDLE;
            endcase
            if (rng == 64'd0) $fatal(1, "RAM_SHIM rng reached zero");
        end
    end

    // Trace: sampled with pre-edge values at the same edges the state machine uses.
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            trace_cyc <= 0;
        end else begin
            trace_cyc <= trace_cyc + 1;
            if (trace_en0 || trace_en1) begin
                if (state == S_IDLE && up.valid && up.ready && traced(up.addr))
                    $display("RAM_SHIM_TRACE cyc=%0d ev=ACC wen=%b addr=%h wdata=%h wmask=%h",
                             trace_cyc, up.wen, up.addr, up.wdata, up.wmask);
                if (state == S_ISSUE && down.ready && traced(addr_q))
                    $display("RAM_SHIM_TRACE cyc=%0d ev=ISS wen=%b addr=%h wdata=%h wmask=%h",
                             trace_cyc, wen_q, addr_q, wdata_q, wmask_q);
                if (state == S_WAIT && down.rvalid && traced(addr_q))
                    $display("RAM_SHIM_TRACE cyc=%0d ev=DRSP wen=%b addr=%h wdata=%h wmask=%h rdata=%h",
                             trace_cyc, wen_q, addr_q, wdata_q, wmask_q, down.rdata);
                if (rvalid_q && traced(addr_q))
                    $display("RAM_SHIM_TRACE cyc=%0d ev=URSP wen=%b addr=%h wdata=%h wmask=%h rdata=%h",
                             trace_cyc, wen_q, addr_q, wdata_q, wmask_q, rdata_q);
            end
        end
    end

    // Downstream must answer only the issued request (one response per request).
    always_ff @(posedge clk) begin
        if (rst && down.rvalid && state != S_WAIT)
            $fatal(1, "RAM_SHIM: downstream rvalid without outstanding request (state=%0d)", state);
    end

    final begin
        $display("RAM_SHIM stats requests=%0d writes=%0d max_latency=%0d refresh_stalls=%0d",
                 stat_requests, stat_writes, stat_max_latency, stat_refresh_stalls);
    end
endmodule
