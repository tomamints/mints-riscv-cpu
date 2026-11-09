// ram_1r1w_be64: 64-bit simple dual-port RAM bank (1 write port, 1 read port,
// one clock) with 8-bit byte enables, written for Quartus M10K inference.
//
// Timing (synchronous 1-cycle read, no extra output pipeline):
//   * At rising edge N the bank samples we/waddr/wbe/wdata and re/raddr.
//   * Write: bytes with wbe[i]=1 at waddr are updated at edge N.
//   * Read:  if re=1 at edge N, rdata is updated at edge N (non-blocking) with
//            the word at raddr; the consumer samples rdata at edge N+1.
//            If re=0 at edge N, rdata keeps its previous value.
//   * Collision: we && |wbe && re && waddr == raddr in the same cycle is
//     FORBIDDEN; the read result is not defined (no_rw_check). A write with
//     wbe == 0 is not a write and may coincide with a read of the same address.
//     The bank provides no bypass; a byte-merge bypass cannot restore bytes the
//     RAM returned as "don't care", so callers must avoid the collision (stall
//     and retry the read, or keep the full old word elsewhere).
//   * Simulation-only: the collision is a fatal assertion.
//
// STYLE (synthesis attribute only; identical behavior in simulation):
//   0 = no attribute (tool choice), 1 = ramstyle "M10K",
//   2 = ramstyle "M10K, no_rw_check".
module ram_1r1w_be64 #(
    parameter int unsigned DEPTH = 128,     // power of two
    parameter int unsigned STYLE = 2
) (
    input  logic                     clk,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [7:0]               wbe,
    input  logic [63:0]              wdata,
    input  logic                     re,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [63:0]              rdata
);

    // synthesis translate_off
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0 || STYLE > 2) begin : g_param_error
        $error("ram_1r1w_be64: DEPTH must be a power of two >= 2 and STYLE <= 2 (DEPTH=%0d STYLE=%0d)",
               DEPTH, STYLE);
    end

    always @(posedge clk) begin
        if (we && (wbe != 8'h00) && re && (waddr == raddr))
            $fatal(1, "ram_1r1w_be64: forbidden read-during-write collision at address %0d (wbe=%02x)",
                   waddr, wbe);
    end
    // synthesis translate_on

    // Explicit generate/endgenerate: Quartus 20.1 Lite rejects bare module-level
    // generate-if/for (Error 10170).
    generate
    if (STYLE == 2) begin : g_m10k_norw
        (* ramstyle = "M10K, no_rw_check" *) logic [7:0][7:0] mem [DEPTH];
        always_ff @(posedge clk) begin
            if (we) begin
                if (wbe[0]) mem[waddr][0] <= wdata[ 7: 0];
                if (wbe[1]) mem[waddr][1] <= wdata[15: 8];
                if (wbe[2]) mem[waddr][2] <= wdata[23:16];
                if (wbe[3]) mem[waddr][3] <= wdata[31:24];
                if (wbe[4]) mem[waddr][4] <= wdata[39:32];
                if (wbe[5]) mem[waddr][5] <= wdata[47:40];
                if (wbe[6]) mem[waddr][6] <= wdata[55:48];
                if (wbe[7]) mem[waddr][7] <= wdata[63:56];
            end
            if (re) rdata <= mem[raddr];
        end
    end else if (STYLE == 1) begin : g_m10k
        (* ramstyle = "M10K" *) logic [7:0][7:0] mem [DEPTH];
        always_ff @(posedge clk) begin
            if (we) begin
                if (wbe[0]) mem[waddr][0] <= wdata[ 7: 0];
                if (wbe[1]) mem[waddr][1] <= wdata[15: 8];
                if (wbe[2]) mem[waddr][2] <= wdata[23:16];
                if (wbe[3]) mem[waddr][3] <= wdata[31:24];
                if (wbe[4]) mem[waddr][4] <= wdata[39:32];
                if (wbe[5]) mem[waddr][5] <= wdata[47:40];
                if (wbe[6]) mem[waddr][6] <= wdata[55:48];
                if (wbe[7]) mem[waddr][7] <= wdata[63:56];
            end
            if (re) rdata <= mem[raddr];
        end
    end else begin : g_auto
        logic [7:0][7:0] mem [DEPTH];
        always_ff @(posedge clk) begin
            if (we) begin
                if (wbe[0]) mem[waddr][0] <= wdata[ 7: 0];
                if (wbe[1]) mem[waddr][1] <= wdata[15: 8];
                if (wbe[2]) mem[waddr][2] <= wdata[23:16];
                if (wbe[3]) mem[waddr][3] <= wdata[31:24];
                if (wbe[4]) mem[waddr][4] <= wdata[39:32];
                if (wbe[5]) mem[waddr][5] <= wdata[47:40];
                if (wbe[6]) mem[waddr][6] <= wdata[55:48];
                if (wbe[7]) mem[waddr][7] <= wdata[63:56];
            end
            if (re) rdata <= mem[raddr];
        end
    end
    endgenerate

endmodule : ram_1r1w_be64
