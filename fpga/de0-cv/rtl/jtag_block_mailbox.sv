// Block transport between a JTAG host and boot_memory_loader.
//
// TCK side (virtual JTAG data register, IR selects):
//   IR 0 STATUS: capture the 64-bit status word below, shift it out.
//   IR 1 CMD   : shift exactly 64 bits; on Update-DR, if no command is in
//                flight, the word becomes the command and req toggles.
//                A wrong length or a command while busy is dropped and
//                sets the sticky cmd_dropped flag (cleared by the next
//                accepted command).
//   IR 2 DATA  : shift 64*N bits (word 0 first, LSB first). Shifted-in words
//                go to the down buffer; a word shifted while busy or past
//                BLOCK_WORDS is ignored and sets data_dropped (cleared at
//                the start of the next DATA scan). While data_dropped is set
//                every command is dropped. Shifted-out words come from the
//                up buffer (read results).
// clk side: on a req toggle the command is executed through the loader, the
// result is stored, and one clk cycle later ack toggles. The host waits for
// ack == req in STATUS, then reads the result and up-buffer data.
//
// CDC: the command word, the down buffer and the result registers are only
// written while the other side treats them as stable (req/ack toggle
// handshake through two-flop synchronizers): the TCK side changes cmd_q and
// the down buffer only when req == ack_sync, and the clk side changes the
// result and the up buffer only between seeing a req toggle and toggling ack.
// memory_fault is the only live status bit and goes through its own
// synchronizer.
//
// Command word: [63:48] 16'h4A42 ("JB"), [47:16] word offset (byte offset/8),
// [15:2] count (1..BLOCK_WORDS, used by WRITE/READ), [1:0] op:
//   0 WRITE: down[0..count-1] -> RAM[offset..], full-word mask
//   1 READ : RAM[offset..] -> up[0..count-1]
//   2 CLEAR: loader clear-all-RAM
//   3 RELEASE: loader release with data = down[0] (must be "MINTSRUN")
// A malformed command (bad magic/count) completes with error, no RAM access.
// A loader error response stops the block; result_count = words completed.
//
// Status word: [63:48] 16'h4A4D ("JM"), [47:32] result_count,
// [31:24] log2(BLOCK_WORDS), [11] data_dropped, [10] cmd_dropped,
// [9:8] result_op, [6] memory_fault, [5] loader fault, [4] cpu_run,
// [3] cleared, [2] result_error, [1] ack (synchronized), [0] req.
module jtag_block_mailbox #(
    parameter int unsigned BLOCK_WORDS = 1024
) (
    // TCK domain (sld_virtual_jtag)
    input  logic       tck,
    input  logic       tdi,
    output logic       tdo,
    input  logic [1:0] ir,
    input  logic       cdr,
    input  logic       sdr,
    input  logic       udr,
    // clk domain
    input  logic        clk,
    input  logic        rst_n,
    output logic        cmd_valid,
    input  logic        cmd_ready,
    output logic [1:0]  cmd_op,
    output logic [63:0] cmd_offset,
    output logic [63:0] cmd_data,
    output logic [7:0]  cmd_mask,
    input  logic        rsp_valid,
    output logic        rsp_ready,
    input  logic        rsp_error,
    input  logic [63:0] rsp_data,
    input  logic        cpu_run,
    input  logic        cleared,
    input  logic        loader_fault,
    input  logic        memory_fault
);
    localparam int unsigned PTR_W = $clog2(BLOCK_WORDS);
    localparam logic [1:0] IR_STATUS = 2'd0, IR_CMD = 2'd1, IR_DATA = 2'd2;

    // Dual-clock buffers: down (TCK write, clk read), up (clk write, TCK read).
    logic [63:0] down_mem [BLOCK_WORDS];
    logic [63:0] up_mem [BLOCK_WORDS];

    // ---------------- TCK domain ----------------
    logic        req_t;
    logic        ack_meta, ack_sync;
    logic        mf_meta, mf_sync;
    logic [63:0] cmd_q;
    logic [63:0] sr;
    logic [6:0]  nbits;          // bits shifted in this scan, saturating at 65
    logic [5:0]  bit_cnt;
    logic [PTR_W-1:0] word_ptr;
    logic        word_ovf;
    logic        cmd_dropped, data_dropped;
    logic [PTR_W-1:0] up_raddr;
    logic [63:0] up_rdata;
    logic        busy_t;
    logic        ack_c;          // clk-domain ack toggle
    // clk-domain result registers, read in TCK only while busy_t == 0
    logic        res_error;
    logic [1:0]  res_op;
    logic [15:0] res_count;
    logic        res_cpu_run, res_cleared, res_fault;

    assign busy_t = req_t != ack_sync;
    assign tdo = sr[0];
    assign up_raddr = (sdr && ir == IR_DATA) ? PTR_W'(word_ptr + PTR_W'(1)) : '0;

    always_ff @(posedge tck) up_rdata <= up_mem[up_raddr];

    logic [63:0] status_word;
    always_comb begin
        status_word = '0;
        status_word[63:48] = 16'h4A4D;
        status_word[31:24] = 8'(PTR_W);
        status_word[11] = data_dropped;
        status_word[10] = cmd_dropped;
        status_word[6] = mf_sync;
        status_word[1] = ack_sync;
        status_word[0] = req_t;
        if (!busy_t) begin
            status_word[47:32] = res_count;
            status_word[9:8] = res_op;
            status_word[5] = res_fault;
            status_word[4] = res_cpu_run;
            status_word[3] = res_cleared;
            status_word[2] = res_error;
        end
    end

    initial begin
        req_t = 1'b0; ack_meta = 1'b0; ack_sync = 1'b0; mf_meta = 1'b0; mf_sync = 1'b0;
        cmd_q = '0; sr = '0; nbits = '0; bit_cnt = '0; word_ptr = '0; word_ovf = 1'b0;
        cmd_dropped = 1'b0; data_dropped = 1'b0;
    end

    always_ff @(posedge tck) begin
        ack_meta <= ack_c; ack_sync <= ack_meta;
        mf_meta <= memory_fault; mf_sync <= mf_meta;
        if (cdr) begin
            nbits <= '0; bit_cnt <= '0; word_ptr <= '0; word_ovf <= 1'b0;
            if (ir == IR_DATA) data_dropped <= 1'b0;
            case (ir)
                IR_STATUS: sr <= status_word;
                IR_CMD:    sr <= cmd_q;
                IR_DATA:   sr <= up_rdata;
                default:   sr <= '0;
            endcase
        end else if (sdr) begin
            sr <= {tdi, sr[63:1]};
            bit_cnt <= bit_cnt + 6'd1;
            if (nbits != 7'd65) nbits <= nbits + 7'd1;
            if (ir == IR_DATA && bit_cnt == 6'd63) begin
                if (busy_t || word_ovf) data_dropped <= 1'b1;
                else down_mem[word_ptr] <= {tdi, sr[63:1]};
                sr <= up_rdata;
                word_ptr <= word_ptr + PTR_W'(1);
                if (word_ptr == PTR_W'(BLOCK_WORDS - 1)) word_ovf <= 1'b1;
            end
        end else if (udr && ir == IR_CMD) begin
            if (!busy_t && !data_dropped && nbits == 7'd64) begin
                cmd_q <= sr;
                req_t <= ~req_t;
                cmd_dropped <= 1'b0;
            end else begin
                cmd_dropped <= 1'b1;
            end
        end
    end

    // ---------------- clk domain ----------------
    typedef enum logic [2:0] {E_IDLE, E_DECODE, E_FETCH, E_ISSUE, E_WAIT, E_DONE, E_ACK} estate_t;
    estate_t st;
    logic req_meta, req_sync, req_seen;
    logic [63:0] cmd_c;
    logic [1:0]  op_c;
    logic [14:0] count_c, idx;
    logic [63:0] base_c;
    logic [63:0] down_rdata;
    logic [PTR_W-1:0] down_raddr;
    logic        up_we;

    assign down_raddr = idx[PTR_W-1:0];
    always_ff @(posedge clk) down_rdata <= down_mem[down_raddr];
    always_ff @(posedge clk) if (up_we) up_mem[idx[PTR_W-1:0]] <= rsp_data;
    assign up_we = st == E_WAIT && rsp_valid && op_c == 2'd1 && !rsp_error;

    assign cmd_valid  = st == E_ISSUE;
    assign cmd_op     = op_c;
    assign cmd_offset = base_c + {46'd0, idx, 3'b000};
    assign cmd_data   = down_rdata;
    assign cmd_mask   = 8'hff;
    assign rsp_ready  = st == E_WAIT;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= E_IDLE; ack_c <= 1'b0; req_meta <= 1'b0; req_sync <= 1'b0; req_seen <= 1'b0;
            cmd_c <= '0; op_c <= '0; count_c <= '0; idx <= '0; base_c <= '0;
            res_error <= 1'b0; res_op <= '0; res_count <= '0;
            res_cpu_run <= 1'b0; res_cleared <= 1'b0; res_fault <= 1'b0;
        end else begin
            req_meta <= req_t; req_sync <= req_meta;
            case (st)
                E_IDLE: if (req_sync != req_seen) begin
                    req_seen <= req_sync;
                    cmd_c <= cmd_q;     // stable: TCK holds it until ack
                    st <= E_DECODE;
                end
                E_DECODE: begin
                    op_c <= cmd_c[1:0];
                    count_c <= {1'b0, cmd_c[15:2]};
                    base_c <= {29'd0, cmd_c[47:16], 3'b000};
                    idx <= '0;
                    res_error <= 1'b0; res_count <= '0; res_op <= cmd_c[1:0];
                    if (cmd_c[63:48] != 16'h4A42 ||
                        (cmd_c[1] == 1'b0 &&
                         (cmd_c[15:2] == 14'd0 || 15'(cmd_c[15:2]) > 15'(BLOCK_WORDS)))) begin
                        res_error <= 1'b1;
                        st <= E_DONE;
                    end else begin
                        st <= E_FETCH;
                    end
                end
                E_FETCH: st <= E_ISSUE; // down_rdata valid for idx
                E_ISSUE: begin
                    if (cmd_ready) st <= E_WAIT;
                    else if (loader_fault || memory_fault || cpu_run) begin
                        res_error <= 1'b1;   // loader will not accept: report, do not hang
                        st <= E_DONE;
                    end
                end
                E_WAIT: if (rsp_valid) begin
                    if (rsp_error) begin
                        res_error <= 1'b1;
                        st <= E_DONE;
                    end else begin
                        res_count <= 16'(idx + 15'd1);
                        if (op_c[1] || idx + 15'd1 == count_c) st <= E_DONE;
                        else begin
                            idx <= idx + 15'd1;
                            st <= E_FETCH;
                        end
                    end
                end
                E_DONE: begin
                    // flags reflect the loader after the response was consumed
                    res_cpu_run <= cpu_run; res_cleared <= cleared; res_fault <= loader_fault;
                    st <= E_ACK;
                end
                E_ACK: begin
                    ack_c <= req_seen;
                    st <= E_IDLE;
                end
                default: st <= E_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial if (BLOCK_WORDS < 2 || (BLOCK_WORDS & (BLOCK_WORDS - 1)) != 0 || BLOCK_WORDS > 8192)
        $fatal(1, "jtag_block_mailbox: BLOCK_WORDS must be a power of two in 2..8192");
`endif
endmodule
