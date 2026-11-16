// RAM-port Membus -> sdram_bridge64 adapter (C3 M3a).
//
// Upstream: the 64-bit RAM Membus after mmio_controller/ram_arbiter. `addr` is
// the byte offset from the RAM base; wdata/wmask are already lane-placed in the
// 8-byte word (addr[2:0] may be non-zero; the word is addr & ~7).
// Downstream: sdram_bridge64 request/response (absolute address, 8-aligned).
//
// Contract (C3 R1-R3):
//   - a request is taken only at up.valid && up.ready; ready never depends on
//     upstream valid or payload; the bridge handshake (req_valid && req_ready)
//     happens exactly in an in-range upstream handshake cycle. req_valid itself
//     follows upstream valid (it may be high while req_ready is low, as on any
//     valid/ready port); the bridge has no side effect before its handshake;
//   - one outstanding request; reads and writes get exactly one response; a
//     write response means performed (bridge/native16 semantics);
//   - no handshake and no response while rst_n or soft_reset is asserted.
// Range: the offset is checked against RAM_SIZE BEFORE the base is added, so an
// offset >= RAM_SIZE can never alias into the valid region.
// Fault (interim until the Membus error path exists): an out-of-range request,
// a bridge error or a response without an outstanding request latches `fault`.
// While `fault` is set there is no ready, no bridge request and no upstream
// response (never reported as success). An unexpected response also blocks
// acceptance in the cycle it arrives, so no request is taken or forwarded then.
// `fault` clears on rst_n or soft_reset; `fault_seen` and the snapshot clear
// only on the cold reset (rst_n). For kind 2/3 the snapshot is the last
// accepted request (offset/abs/wen).
// Simulation: a fault is $fatal unless +MEMBUS_SDRAM_FAULT_NONFATAL is given.
// Resets: rst_n is the cold (power/PLL) reset. soft_reset is the warm CPU reset
// pulse; it cancels the outstanding request (the bridge/native16 soft_reset
// suppress its response and keep refresh running). A loader that holds the CPU
// in reset must NOT drive soft_reset for that whole time.
module membus_sdram_adapter #(
    parameter logic [63:0] RAM_BASE = 64'h8000_0000,
    parameter logic [63:0] RAM_SIZE = 64'h0400_0000   // must match sdram_bridge64
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        soft_reset,
    Membus.slave        up,
    // sdram_bridge64 request side
    output logic        req_valid,
    input  logic        req_ready,
    output logic [63:0] req_addr,
    output logic        req_write,
    output logic [63:0] req_wdata,
    output logic [7:0]  req_be,
    input  logic        rsp_valid,
    input  logic [63:0] rsp_data,
    input  logic        rsp_error,
    // diagnostics
    output logic        fault,
    output logic        fault_seen,
    output logic [1:0]  fault_kind,      // 1 range, 2 bridge error, 3 protocol
    output logic [63:0] fault_offset,    // original upstream offset
    output logic [63:0] fault_abs,       // computed absolute address
    output logic        fault_wen
);
    localparam logic [1:0] FK_RANGE = 2'd1, FK_BRIDGE = 2'd2, FK_PROTOCOL = 2'd3;

    logic        busy;           // request accepted, bridge response pending
    logic [63:0] saved_offset;
    logic        saved_wen;

    wire         active    = rst_n && !soft_reset && !fault;
    wire [63:0]  offset    = 64'(up.addr);
    wire         in_range  = offset < RAM_SIZE;
    wire [63:0]  word_abs  = RAM_BASE + {offset[63:3], 3'b000};
    wire         up_fire   = up.valid && up.ready;

    // ready: adapter state, the bridge's (state-only) ready and the absence of
    // an unexpected response; never upstream valid or payload.
    wire         unexpected_rsp = !busy && rsp_valid;
    assign up.ready  = active && !busy && req_ready && !unexpected_rsp;
    // Only an in-range request is presented; it is taken exactly at up_fire.
    assign req_valid = active && !busy && up.valid && in_range && !unexpected_rsp;
    assign req_addr  = word_abs;
    assign req_write = up.wen;
    assign req_wdata = up.wdata;
    assign req_be    = up.wen ? up.wmask : 8'hff;
    // Response passes through only for the outstanding request.
    assign up.rvalid = active && busy && rsp_valid && !rsp_error;
    assign up.rdata  = rsp_data;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            saved_offset <= '0;
            saved_wen    <= 1'b0;
            fault        <= 1'b0;
            fault_seen   <= 1'b0;
            fault_kind   <= '0;
            fault_offset <= '0;
            fault_abs    <= '0;
            fault_wen    <= 1'b0;
        end else if (soft_reset) begin
            busy  <= 1'b0;
            fault <= 1'b0;
        end else if (!fault) begin
            if (busy && rsp_valid) begin
                busy <= 1'b0;
                if (rsp_error) begin
                    fault <= 1'b1; fault_seen <= 1'b1; fault_kind <= FK_BRIDGE;
                    fault_offset <= saved_offset;
                    fault_abs <= RAM_BASE + {saved_offset[63:3], 3'b000};
                    fault_wen <= saved_wen;
                end
            end else if (unexpected_rsp) begin
                fault <= 1'b1; fault_seen <= 1'b1; fault_kind <= FK_PROTOCOL;
                fault_offset <= saved_offset;
                fault_abs <= RAM_BASE + {saved_offset[63:3], 3'b000};
                fault_wen <= saved_wen;
            end
            if (up_fire) begin
                saved_offset <= offset;
                saved_wen    <= up.wen;
                if (in_range) begin
                    busy <= 1'b1;
                end else begin
                    fault <= 1'b1; fault_seen <= 1'b1; fault_kind <= FK_RANGE;
                    fault_offset <= offset; fault_abs <= word_abs; fault_wen <= up.wen;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (RAM_SIZE != 64'h0400_0000 || RAM_BASE != 64'h8000_0000)
            $fatal(1, "membus_sdram_adapter: RAM_BASE/RAM_SIZE must match sdram_bridge64 (0x80000000, 64 MiB)");
        if ($bits(up.addr) != 64 || $bits(up.wdata) != 64 || $bits(up.wmask) != 8)
            $fatal(1, "membus_sdram_adapter: expected a 64-bit Membus");
    end
    // Report each new fault once (sampled one cycle after it latches).
    logic fault_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_prev <= 1'b0;
        end else begin
            if (fault && !fault_prev) begin
                if ($test$plusargs("MEMBUS_SDRAM_FAULT_NONFATAL"))
                    $display("MEMBUS_SDRAM_FAULT kind=%0d offset=%h abs=%h wen=%b", fault_kind, fault_offset, fault_abs, fault_wen);
                else
                    $fatal(1, "MEMBUS_SDRAM_FAULT kind=%0d offset=%h abs=%h wen=%b", fault_kind, fault_offset, fault_abs, fault_wen);
            end
            fault_prev <= fault;
        end
    end
`endif
endmodule
