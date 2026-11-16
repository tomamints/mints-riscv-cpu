// Clock-synchronous command-level SDR SDRAM model (x16, 4 banks, 8K rows,
// 1K columns) for CPU-level simulation without --timing (C3 M3b).
// Independent of the controller: it decodes the pins only, checks JEDEC rules
// with timings derived from datasheet nanoseconds (IS42S16320D -7) rounded up to
// cycles at CLK_HZ, and accepts only the MRS configuration it implements
// (BL1, sequential, CL3, single-location write burst off = programmed burst).
//
// Sampling: commands, address, DQM and write data are registered by the
// controller on clk; the model samples them on the next clk edge. The physical
// quarter-period memory-clock phase is a board-timing property covered by STA
// and by the timing-mode pin model; here every event keeps its edge order.
// Read data (CAS latency CL = 3): a READ issued at controller edge E is sampled
// here at E+1; its data is driven at edge E+CL-1 (= E+2) so it is valid only
// for the capture edge E+CL (= E+3). At every other edge DQ carries a distinct
// garbage pattern, so an early or late capture is detected. Read DQM has
// latency 2: the mask issued at E+CL-2 (= E+1) masks that data; the model
// samples it at E+2, i.e. at the edge where it drives the data.
module sdram_cycle_model16 #(
    parameter int unsigned CLK_HZ = 20_000_000,
    parameter logic [15:0] UNWRITTEN = 16'h0000   // value read from never-written cells
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [12:0] a,
    input  logic [1:0]  ba,
    input  logic [1:0]  dqm,
    input  logic        cke, csn, rasn, casn, wen,
    input  logic        oe,
    input  logic [15:0] dout,
    output logic [15:0] din
);
    // ---- datasheet timings (ns) -> cycles, rounded up ----
    localparam longint PS_PER_S  = 64'd1_000_000_000_000;
    localparam longint PERIOD_PS = PS_PER_S / longint'(CLK_HZ);
    function automatic longint cyc_of(input longint ps);               // round up
        return (ps + PERIOD_PS - 1) / PERIOD_PS;
    endfunction
    localparam longint T_RCD  = cyc_of(18_000);
    localparam longint T_RP   = cyc_of(18_000);
    localparam longint T_RAS  = cyc_of(42_000);
    localparam longint T_RASX = 64'd100_000_000 / PERIOD_PS;           // 100 us maximum (floor)
    localparam longint T_RC   = cyc_of(60_000);
    localparam longint T_RFC  = cyc_of(60_000);
    localparam longint T_WR   = cyc_of(14_000);
    localparam longint T_MRD  = 2;
    localparam longint T_PWR  = cyc_of(100_000_000);                   // 100 us power-up
    localparam longint T_REFI = 64'd7_812_500 / PERIOD_PS;             // 64 ms / 8192 (floor)
    localparam logic [2:0] CL = 3'd3;   // the only CAS latency accepted in the mode register

    localparam logic [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                           C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;

    logic [15:0] mem [logic [24:0]];
    longint cyc;
    bit configured;
    bit pre_all_seen;                   // a PRE with A10 (all banks) since reset
    int unsigned refs_since_pre;
    longint first_cmd_ok, last_ref, last_mrs, last_pre_any;
    bit open [4];
    logic [12:0] row [4];
    longint act_at [4], pre_at [4], wr_at [4];
    // read pipeline: one stage for CL = 3 (sampled at E+1, driven at E+2)
    bit          rd_pend;
    logic [15:0] rd_word;

    function automatic logic [15:0] garbage(input logic [15:0] c);
        return 16'hbad0 ^ c;
    endfunction

    // Plain always (TB model): the memory array is updated with blocking assignments.
    /* verilator lint_off BLKSEQ */
    // The array is not cleared by rst_n (a device keeps its contents); timing state is.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; configured <= 0; pre_all_seen <= 0; refs_since_pre <= 0;
            first_cmd_ok <= T_PWR; last_ref <= -1_000_000; last_mrs <= -1_000_000; last_pre_any <= -1_000_000;
            for (int b = 0; b < 4; b++) begin open[b] <= 0; row[b] <= '0; act_at[b] <= -1_000_000; pre_at[b] <= -1_000_000; wr_at[b] <= -1_000_000; end
            rd_pend <= 0; rd_word <= '0;
            din <= garbage('0);
        end else begin
            logic [3:0] cmd;
            longint e;            // controller edge that issued the sampled command
            cmd = csn ? C_NOP : {1'b0, rasn, casn, wen};   // deselect (CS# high) = NOP
            e = cyc;              // sampled now, issued one edge earlier: intervals are relative
            cyc <= cyc + 1;
            if (!cke) $fatal(1, "sdram_cycle_model16: CKE low is not modelled");

            // ---- read data output for the next capture edge ----
            // rd_pend was set one edge ago by a sampled READ (issued two edges ago);
            // the DQM sampled now was issued one edge after that READ (latency 2).
            if (rd_pend) begin
                logic [15:0] g;
                g = garbage(e[15:0]);
                din[7:0]  <= dqm[0] ? g[7:0]  : rd_word[7:0];
                din[15:8] <= dqm[1] ? g[15:8] : rd_word[15:8];
            end else begin
                din <= garbage(e[15:0]);
            end
            rd_pend <= 0;

            if (cmd != C_NOP && e < first_cmd_ok) $fatal(1, "sdram_cycle_model16: command before 100 us power-up (edge %0d)", e);
            if (cmd != C_NOP && last_ref >= 0 && e - last_ref < T_RFC) $fatal(1, "sdram_cycle_model16: command within tRFC of REF");
            if (cmd != C_NOP && cmd != C_MRS && last_mrs >= 0 && e - last_mrs < T_MRD) $fatal(1, "sdram_cycle_model16: command within tMRD of MRS");
            if (configured && last_ref >= 0 && e - last_ref > T_REFI) $fatal(1, "sdram_cycle_model16: refresh interval %0d > %0d", e - last_ref, T_REFI);
            for (int b = 0; b < 4; b++)
                if (open[b] && e - act_at[b] > T_RASX) $fatal(1, "sdram_cycle_model16: bank %0d open longer than tRAS max", b);

            unique case (cmd)
                C_NOP: ;
                C_PRE: begin
                    for (int b = 0; b < 4; b++) if (a[10] || ba == 2'(b)) begin
                        if (open[b]) begin
                            if (e - act_at[b] < T_RAS) $fatal(1, "sdram_cycle_model16: tRAS violated bank %0d", b);
                            if (e - wr_at[b] < T_WR) $fatal(1, "sdram_cycle_model16: tWR violated bank %0d", b);
                        end
                        open[b] <= 0; pre_at[b] <= e;
                    end
                    if (a[10]) begin last_pre_any <= e; pre_all_seen <= 1; refs_since_pre <= 0; end
                end
                C_REF: begin
                    for (int b = 0; b < 4; b++) begin
                        if (open[b]) $fatal(1, "sdram_cycle_model16: REF with bank %0d open", b);
                        if (e - pre_at[b] < T_RP) $fatal(1, "sdram_cycle_model16: REF within tRP");
                    end
                    last_ref <= e; refs_since_pre <= refs_since_pre + 1;
                end
                C_MRS: begin
                    for (int b = 0; b < 4; b++) if (open[b]) $fatal(1, "sdram_cycle_model16: MRS with a bank open");
                    // A2:0 burst length 000 = 1, A3 sequential, A6:4 CAS latency, A8:7 = 00 (standard
                    // operation), A9 = 0 (programmed burst for writes), A12:10 reserved = 0, BA = 0
                    if (a[2:0] != 3'b000 || a[3] || a[6:4] != CL || a[8:7] != 2'b00 || a[9] || a[12:10] != 3'b000 || ba != 2'b00)
                        $fatal(1, "sdram_cycle_model16: unsupported mode register %h (ba %0d)", a, ba);
                    if (!pre_all_seen || refs_since_pre < 2)
                        $fatal(1, "sdram_cycle_model16: MRS requires PRE all followed by 2 REF (pre_all=%0b refs=%0d)", pre_all_seen, refs_since_pre);
                    if (e - last_pre_any < T_RP) $fatal(1, "sdram_cycle_model16: MRS within tRP of PRE all");
                    configured <= 1; last_mrs <= e;
                end
                C_ACT: begin
                    if (!configured) $fatal(1, "sdram_cycle_model16: ACT before MRS");
                    if (open[ba]) $fatal(1, "sdram_cycle_model16: ACT to open bank %0d", ba);
                    if (e - pre_at[ba] < T_RP) $fatal(1, "sdram_cycle_model16: tRP violated bank %0d", ba);
                    if (e - act_at[ba] < T_RC) $fatal(1, "sdram_cycle_model16: tRC violated bank %0d", ba);
                    open[ba] <= 1; row[ba] <= a; act_at[ba] <= e; wr_at[ba] <= -1_000_000;
                end
                C_WR, C_RD: begin
                    if (!open[ba]) $fatal(1, "sdram_cycle_model16: access to closed bank %0d", ba);
                    if (e - act_at[ba] < T_RCD) $fatal(1, "sdram_cycle_model16: tRCD violated bank %0d", ba);
                    if (a[10]) $fatal(1, "sdram_cycle_model16: auto-precharge is not modelled");
                    if (cmd == C_WR) begin
                        logic [24:0] k; logic [15:0] old;
                        if (!oe) $fatal(1, "sdram_cycle_model16: WRITE without DQ drive");
                        k = {row[ba], ba, a[9:0]};
                        old = mem.exists(k) ? mem[k] : UNWRITTEN;
                        mem[k] = {dqm[1] ? old[15:8] : dout[15:8], dqm[0] ? old[7:0] : dout[7:0]};
                        wr_at[ba] <= e;
                    end else begin
                        logic [24:0] k;
                        if (oe) $fatal(1, "sdram_cycle_model16: READ while the controller drives DQ");
                        k = {row[ba], ba, a[9:0]};
                        rd_pend <= 1; rd_word <= mem.exists(k) ? mem[k] : UNWRITTEN;
                    end
                end
                default: $fatal(1, "sdram_cycle_model16: unsupported command %b", cmd);
            endcase
        end
    end
    /* verilator lint_on BLKSEQ */
endmodule
