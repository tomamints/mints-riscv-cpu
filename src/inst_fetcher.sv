import eei::*;
import corectrl::*;

module inst_fetcher (
    input  logic             clk,
    input  logic             rst,
    input  PrivMode          priv_mode,
    input  UIntX             pmpcfg0,
    input  UIntX             pmpaddr0,
    input  UIntX             pmpaddr1,
    input  UIntX             pmpaddr2,
    input  UIntX             pmpaddr3,
    core_inst_if.slave       core_if,
    Membus.master            mem_if
);

    // ---------------- fetch FIFO ----------------
    typedef struct packed {
        Addr                              addr;
        logic [MEMBUS_DATA_WIDTH-1:0]     bits;
        ExceptionInfo                     expt;
    } fetch_fifo_type;

    logic           fetch_fifo_flush;
    logic           fetch_fifo_wvalid;
    logic           fetch_fifo_wready;
    fetch_fifo_type fetch_fifo_wdata;
    fetch_fifo_type fetch_fifo_rdata;
    logic           fetch_fifo_rready;
    logic           fetch_fifo_rvalid;

    fifo #(
        .DATA_TYPE (fetch_fifo_type),
        .WIDTH     (3)
    ) fetch_fifo (
        .clk         (clk),
        .rst         (rst),
        .flush       (fetch_fifo_flush),
        .wready      (),                // unused (Veryl: _)
        .wready_two  (fetch_fifo_wready),
        .wvalid      (fetch_fifo_wvalid),
        .wdata       (fetch_fifo_wdata),
        .rready      (fetch_fifo_rready),
        .rvalid      (fetch_fifo_rvalid),
        .rdata       (fetch_fifo_rdata)
    );

    // ---------------- issue FIFO ----------------
    typedef struct packed {
        Addr  addr;
        Inst  bits;
        logic is_rvc;
        ExceptionInfo expt;
    } issue_fifo_type;

    logic           issue_fifo_flush;
    logic           issue_fifo_wvalid;
    logic           issue_fifo_wready;
    issue_fifo_type issue_fifo_wdata;
    issue_fifo_type issue_fifo_rdata;
    logic           issue_fifo_rready;
    logic           issue_fifo_rvalid;

    fifo #(
        .DATA_TYPE (issue_fifo_type),
        .WIDTH     (3)
    ) issue_fifo (
        .clk    (clk),
        .rst    (rst),
        .flush  (issue_fifo_flush),
        .wready (issue_fifo_wready),
        .wready_two (),
        .wvalid (issue_fifo_wvalid),
        .wdata  (issue_fifo_wdata),
        .rready (issue_fifo_rready),
        .rvalid (issue_fifo_rvalid),
        .rdata  (issue_fifo_rdata)
    );

    /*--------- issue logic ----------*/
    logic [2:0] issue_pc_offset;

    logic       issue_is_rdata_saved;
    Addr        issue_saved_addr;
    logic [15:0] issue_saved_bits;  // rdata[63:48]

    // instruction converter
    logic [15:0] rvcc_inst16;
    logic        rvcc_is_rvc;
    Inst         rvcc_inst32;

    // inst16 の選択（Veryl の inline case 相当）
    always_comb begin
        unique case (issue_pc_offset)
            3'd0: rvcc_inst16 = fetch_fifo_rdata.bits[15:0];
            3'd2: rvcc_inst16 = fetch_fifo_rdata.bits[31:16];
            3'd4: rvcc_inst16 = fetch_fifo_rdata.bits[47:32];
            3'd6: rvcc_inst16 = fetch_fifo_rdata.bits[63:48];
            default: rvcc_inst16 = 16'h0000;
        endcase
    end

    rvc_converter rvcc (
        .inst16 (rvcc_inst16),
        .is_rvc (rvcc_is_rvc),
        .inst32 (rvcc_inst32)
    );

    // issue_pc_offset / saved_* レジスタ
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            issue_pc_offset      <= 3'd0;
            issue_is_rdata_saved <= 1'b0;
            issue_saved_addr     <= '0;
            issue_saved_bits     <= 16'h0000;
        end else begin
            if (core_if.is_hazard) begin
                issue_pc_offset      <= core_if.next_pc[2:0];
                issue_is_rdata_saved <= 1'b0;
            end else begin
                // offset が 6 な 32ビット命令の場合、
                // アドレスと上位16ビットを保存して FIFO を読み進める
                if ((issue_pc_offset == 3'd6) && !rvcc_is_rvc && !issue_is_rdata_saved) begin
                    if (fetch_fifo_rvalid) begin
                        issue_is_rdata_saved <= 1'b1;
                        issue_saved_addr     <= fetch_fifo_rdata.addr;
                        issue_saved_bits     <= fetch_fifo_rdata.bits[63:48];
                    end
                end else begin
                    if (issue_fifo_wready && issue_fifo_wvalid) begin
                        issue_pc_offset      <= issue_pc_offset
                                             + ((issue_is_rdata_saved || !rvcc_is_rvc) ? 3'd4 : 3'd2);
                        issue_is_rdata_saved <= 1'b0;
                    end
                end
            end
        end
    end

    // fetch_fifo <-> issue_fifo
    always_comb begin
        Addr                      raddr;
        logic [MEMBUS_DATA_WIDTH-1:0] rdata;
        logic [2:0]              offset;

        raddr  = fetch_fifo_rdata.addr;
        rdata  = fetch_fifo_rdata.bits;
        offset = issue_pc_offset;

        fetch_fifo_rready = 1'b0;
        issue_fifo_wvalid = 1'b0;
        issue_fifo_wdata  = '0;

        if (!core_if.is_hazard && fetch_fifo_rvalid) begin
            if (issue_fifo_wready) begin
                if (offset == 3'd6) begin
                    // offset が 6 な 32ビット命令の場合、
                    // 命令は {rdata_next[15:0], rdata[63:48]} になる
                    if (issue_is_rdata_saved) begin
                        issue_fifo_wvalid       = 1'b1;
                        issue_fifo_wdata.addr   = {issue_saved_addr[$bits(Addr)-1:3], offset};
                        issue_fifo_wdata.bits   = {rdata[15:0], issue_saved_bits};
                        issue_fifo_wdata.is_rvc = 1'b0;
                        issue_fifo_wdata.expt   = fetch_fifo_rdata.expt;
                    end else begin
                        fetch_fifo_rready = 1'b1;
                        if (rvcc_is_rvc) begin
                            issue_fifo_wvalid       = 1'b1;
                            issue_fifo_wdata.addr   = {raddr[$bits(Addr)-1:3], offset};
                            issue_fifo_wdata.is_rvc = 1'b1;
                            issue_fifo_wdata.bits   = rvcc_inst32;
                            issue_fifo_wdata.expt   = fetch_fifo_rdata.expt;
                        end else begin
                            // Read next 8 bytes (Veryl でも未実装部分)
                        end
                    end
                end else begin
                    fetch_fifo_rready     = (!rvcc_is_rvc && (offset == 3'd4));
                    issue_fifo_wvalid     = 1'b1;
                    issue_fifo_wdata.addr = {raddr[$bits(Addr)-1:3], offset};

                    if (rvcc_is_rvc) begin
                        issue_fifo_wdata.bits = rvcc_inst32;
                    end else begin
                        case (offset)
                            3'd0: issue_fifo_wdata.bits = rdata[31:0];
                            3'd2: issue_fifo_wdata.bits = rdata[47:16];
                            3'd4: issue_fifo_wdata.bits = rdata[63:32];
                            default: issue_fifo_wdata.bits = '0;
                        endcase
                    end
                    issue_fifo_wdata.is_rvc = rvcc_is_rvc;
                    issue_fifo_wdata.expt   = fetch_fifo_rdata.expt;
                end
            end
        end
    end

    // issue_fifo <-> core
    always_comb begin
        issue_fifo_flush  = core_if.is_hazard;
        issue_fifo_rready = core_if.rready;

        core_if.rvalid = issue_fifo_rvalid;
        core_if.raddr  = issue_fifo_rdata.addr;
        core_if.rdata  = issue_fifo_rdata.bits;
        core_if.is_rvc = issue_fifo_rdata.is_rvc;
        core_if.expt   = issue_fifo_rdata.expt;
    end

    /*--------- fetch logic ----------*/
    Addr  fetch_pc;
    logic fetch_requested;
    Addr  fetch_pc_requested;
    logic fetch_pmp_allow;

    pmp_checker pmp_fetch_checker (
        .priv_mode(priv_mode),
        .access_start(fetch_pc),
        .access_size(UIntX'(2)),
        .access_type(PMP_ACCESS_EXEC),
        .pmpcfg0(pmpcfg0),
        .pmpaddr0(pmpaddr0),
        .pmpaddr1(pmpaddr1),
        .pmpaddr2(pmpaddr2),
        .pmpaddr3(pmpaddr3),
        .allow(fetch_pmp_allow)
    );

    // core -> mem_if
    always_comb begin
        mem_if.valid = 1'b0;
        mem_if.addr  = '0;
        mem_if.wen   = 1'b0;
        mem_if.wdata = '0;
        mem_if.wmask = '0;

        if (!core_if.is_hazard) begin
            mem_if.valid = fetch_fifo_wready && fetch_pmp_allow;
            if (fetch_requested) begin
                mem_if.valid = mem_if.valid && mem_if.rvalid;
            end
            mem_if.addr = fetch_pc;
        end
    end

    // memory -> fetch_fifo
    always_comb begin
        fetch_fifo_flush      = core_if.is_hazard;
        fetch_fifo_wvalid     = (fetch_requested && mem_if.rvalid) ||
                                (!fetch_requested && !core_if.is_hazard && fetch_fifo_wready && !fetch_pmp_allow);
        fetch_fifo_wdata.addr = (fetch_requested && mem_if.rvalid) ? fetch_pc_requested : fetch_pc;
        fetch_fifo_wdata.bits = (fetch_requested && mem_if.rvalid) ? mem_if.rdata : '0;
        fetch_fifo_wdata.expt = '0;
        if (!fetch_requested && !core_if.is_hazard && fetch_fifo_wready && !fetch_pmp_allow) begin
            fetch_fifo_wdata.expt.valid = 1'b1;
            fetch_fifo_wdata.expt.cause = INSTRUCTION_ACCESS_FAULT;
            fetch_fifo_wdata.expt.value = fetch_pc;
        end
    end

    // fetch_pc / requested レジスタ
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            fetch_pc           <= INITIAL_PC;
            fetch_requested    <= 1'b0;
            fetch_pc_requested <= '0;
        end else begin
            if (core_if.is_hazard) begin
                fetch_pc           <= {core_if.next_pc[XLEN-1:3], 3'b000};
                fetch_requested    <= 1'b0;
                fetch_pc_requested <= '0;
            end else begin
                if (!fetch_requested && fetch_fifo_wready && !fetch_pmp_allow) begin
                    fetch_pc <= fetch_pc + 2;
                end else if (fetch_requested) begin
                    if (mem_if.rvalid) begin
                        fetch_requested <= mem_if.ready && mem_if.valid;
                        if (mem_if.ready && mem_if.valid) begin
                            fetch_pc_requested <= fetch_pc;
                            fetch_pc           <= fetch_pc + 8;
                        end
                    end
                end else begin
                    if (mem_if.ready && mem_if.valid) begin
                        fetch_requested    <= 1'b1;
                        fetch_pc_requested <= fetch_pc;
                        fetch_pc           <= fetch_pc + 8;
                    end
                end
            end
        end
    end

endmodule
