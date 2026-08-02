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
    input  UIntX             pmpaddr4,
    input  UIntX             pmpaddr5,
    input  UIntX             pmpaddr6,
    input  UIntX             pmpaddr7,
    input  UIntX             satp,
    input  logic             sstatus_sum,
    input  logic             sstatus_mxr,
    input  logic             translation_flush,
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

    Addr  issue_pmp_addr;
    UIntX issue_pmp_size;
    logic issue_pmp_allow_raw;
    logic issue_pmp_allow;

    pmp_checker pmp_issue_checker (
        .priv_mode(priv_mode),
        .access_start(issue_pmp_addr),
        .access_size(issue_pmp_size),
        .access_type(PMP_ACCESS_EXEC),
        .pmpcfg0(pmpcfg0),
        .pmpaddr0(pmpaddr0),
        .pmpaddr1(pmpaddr1),
        .pmpaddr2(pmpaddr2),
        .pmpaddr3(pmpaddr3),
        .pmpaddr4(pmpaddr4),
        .pmpaddr5(pmpaddr5),
        .pmpaddr6(pmpaddr6),
        .pmpaddr7(pmpaddr7),
        .allow(issue_pmp_allow_raw)
    );

    assign issue_pmp_allow = need_translate ? 1'b1 : issue_pmp_allow_raw;

    always_comb begin
        issue_pmp_addr = {fetch_fifo_rdata.addr[$bits(Addr)-1:3], issue_pc_offset};
        issue_pmp_size = rvcc_is_rvc ? UIntX'(2) : UIntX'(4);
        if ((issue_pc_offset == 3'd6) && issue_is_rdata_saved) begin
            issue_pmp_addr = {issue_saved_addr[$bits(Addr)-1:3], issue_pc_offset};
            issue_pmp_size = UIntX'(4);
        end
    end

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
                    if (fetch_fifo_rready && fetch_fifo_rvalid) begin
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
                        if (!issue_fifo_wdata.expt.valid && !issue_pmp_allow) begin
                            issue_fifo_wdata.expt.valid = 1'b1;
                            issue_fifo_wdata.expt.cause = INSTRUCTION_ACCESS_FAULT;
                            issue_fifo_wdata.expt.value = issue_pmp_addr;
                        end
                    end else begin
                        fetch_fifo_rready = 1'b1;
                        if (rvcc_is_rvc) begin
                            issue_fifo_wvalid       = 1'b1;
                            issue_fifo_wdata.addr   = {raddr[$bits(Addr)-1:3], offset};
                            issue_fifo_wdata.is_rvc = 1'b1;
                            issue_fifo_wdata.bits   = rvcc_inst32;
                            issue_fifo_wdata.expt   = fetch_fifo_rdata.expt;
                            if (!issue_fifo_wdata.expt.valid && !issue_pmp_allow) begin
                                issue_fifo_wdata.expt.valid = 1'b1;
                                issue_fifo_wdata.expt.cause = INSTRUCTION_ACCESS_FAULT;
                                issue_fifo_wdata.expt.value = issue_pmp_addr;
                            end
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
                    if (!issue_fifo_wdata.expt.valid && !issue_pmp_allow) begin
                        issue_fifo_wdata.expt.valid = 1'b1;
                        issue_fifo_wdata.expt.cause = INSTRUCTION_ACCESS_FAULT;
                        issue_fifo_wdata.expt.value = issue_pmp_addr;
                    end
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
    Addr  fetch_req_vaddr;
    Addr  fetch_req_paddr;
    logic fetch_pmp_allow;
    logic satp_sv39;
    logic need_translate;
    logic fetch_translation_req_valid;
    logic fetch_translation_req_ready;
    logic fetch_translation_rsp_valid;
    logic fetch_translation_rsp_ready;
    Addr fetch_translation_pa;
    logic fetch_translation_fault;
    Sv39Fault fetch_translation_fault_detail;
    CsrCause fetch_translation_fault_cause;
    Addr fetch_translation_fault_value;
    logic fetch_translation_mem_valid;
    logic fetch_translation_mem_ready;
    logic fetch_translation_mem_rvalid;
    Addr fetch_translation_mem_addr;
    ExceptionInfo fetch_fault_expt;
    logic icache_req_valid;
    logic icache_req_ready;
    Addr icache_req_addr;
    logic icache_rsp_valid;
    logic icache_rsp_ready;
    UInt64 icache_rsp_data;
    logic icache_mem_valid;
    logic icache_mem_ready;
    Addr icache_mem_addr;
    logic icache_mem_rvalid;

    typedef enum logic [1:0] {
        FetchMemOwnerNone,
        FetchMemOwnerIcache,
        FetchMemOwnerPtw
    } FetchMemOwner;

    FetchMemOwner fetch_mem_owner;
    logic fetch_inst_mem_fire;
    logic fetch_inst_mem_rvalid;

    typedef enum logic [2:0] {
        FetchIdle,
        FetchTranslate,
        FetchAccess,
        FetchWaitResp,
        FetchFault
    } FetchState;

    FetchState fetch_state;

    assign satp_sv39 = satp[63:60] == 4'd8;
    assign need_translate = satp_sv39 && (priv_mode != M);
    assign fetch_translation_req_valid =
        fetch_state == FetchIdle &&
        fetch_fifo_wready &&
        need_translate &&
        !core_if.is_hazard;
    assign fetch_translation_rsp_ready = fetch_state == FetchTranslate;

    instruction_translation fetch_translation (
        .clk(clk),
        .rst(rst),
        .flush(core_if.is_hazard),
        .tlb_flush(translation_flush),
        .req_valid(fetch_translation_req_valid),
        .req_ready(fetch_translation_req_ready),
        .req_va(fetch_pc),
        .req_priv_mode(priv_mode),
        .satp(satp),
        .rsp_valid(fetch_translation_rsp_valid),
        .rsp_ready(fetch_translation_rsp_ready),
        .rsp_pa(fetch_translation_pa),
        .rsp_fault(fetch_translation_fault),
        .rsp_fault_detail(fetch_translation_fault_detail),
        .rsp_fault_cause(fetch_translation_fault_cause),
        .rsp_fault_value(fetch_translation_fault_value),
        .ptw_mem_valid(fetch_translation_mem_valid),
        .ptw_mem_addr(fetch_translation_mem_addr),
        .ptw_mem_ready(fetch_translation_mem_ready),
        .ptw_mem_rvalid(fetch_translation_mem_rvalid),
        .ptw_mem_error(1'b0),
        .ptw_mem_rdata(mem_if.rdata)
    );

    icache fetch_icache (
        .clk(clk),
        .rst(rst),
        .cancel(core_if.is_hazard),
        .invalidate(translation_flush),
        .req_valid(icache_req_valid),
        .req_ready(icache_req_ready),
        .req_addr(icache_req_addr),
        .rsp_valid(icache_rsp_valid),
        .rsp_ready(icache_rsp_ready),
        .rsp_data(icache_rsp_data),
        .mem_valid(icache_mem_valid),
        .mem_ready(icache_mem_ready),
        .mem_addr(icache_mem_addr),
        .mem_rvalid(icache_mem_rvalid),
        .mem_rdata(mem_if.rdata)
    );

    pmp_checker pmp_fetch_checker (
        .priv_mode(priv_mode),
        .access_start(need_translate ? fetch_req_paddr : fetch_pc),
        .access_size(UIntX'(8)),
        .access_type(PMP_ACCESS_EXEC),
        .pmpcfg0(pmpcfg0),
        .pmpaddr0(pmpaddr0),
        .pmpaddr1(pmpaddr1),
        .pmpaddr2(pmpaddr2),
        .pmpaddr3(pmpaddr3),
        .pmpaddr4(pmpaddr4),
        .pmpaddr5(pmpaddr5),
        .pmpaddr6(pmpaddr6),
        .pmpaddr7(pmpaddr7),
        .allow(fetch_pmp_allow)
    );

    assign fetch_translation_mem_ready =
        !core_if.is_hazard &&
        fetch_translation_mem_valid &&
        mem_if.ready;
    assign icache_mem_ready =
        !core_if.is_hazard &&
        !fetch_translation_mem_valid &&
        icache_mem_valid &&
        mem_if.ready;
    assign fetch_translation_mem_rvalid =
        mem_if.rvalid &&
        fetch_mem_owner == FetchMemOwnerPtw;
    assign icache_mem_rvalid =
        mem_if.rvalid &&
        fetch_mem_owner == FetchMemOwnerIcache;
    assign icache_req_valid =
        !core_if.is_hazard &&
        fetch_fifo_wready &&
        fetch_pmp_allow &&
        (
            (fetch_state == FetchIdle && !need_translate) ||
            (fetch_state == FetchAccess)
        );
    assign icache_req_addr =
        (fetch_state == FetchIdle && !need_translate) ? fetch_pc : fetch_req_paddr;
    assign icache_rsp_ready =
        fetch_state == FetchWaitResp &&
        fetch_fifo_wready;
    assign fetch_inst_mem_fire =
        icache_req_valid &&
        icache_req_ready;
    assign fetch_inst_mem_rvalid =
        icache_rsp_valid;

    // core -> mem_if
    always_comb begin
        mem_if.valid = 1'b0;
        mem_if.addr  = '0;
        mem_if.wen   = 1'b0;
        mem_if.wdata = '0;
        mem_if.wmask = '0;

        if (!core_if.is_hazard) begin
            if (fetch_translation_mem_valid) begin
                mem_if.valid = 1'b1;
                mem_if.addr = fetch_translation_mem_addr;
            end else if (icache_mem_valid) begin
                mem_if.valid = 1'b1;
                mem_if.addr = icache_mem_addr;
            end
        end
    end

    // memory -> fetch_fifo
    always_comb begin
        fetch_fifo_flush      = core_if.is_hazard;
        fetch_fifo_wvalid     = (fetch_state == FetchWaitResp && fetch_inst_mem_rvalid) ||
                                (fetch_state == FetchFault && fetch_fifo_wready) ||
                                (fetch_state == FetchIdle && !need_translate && !core_if.is_hazard && fetch_fifo_wready && !fetch_pmp_allow);
        fetch_fifo_wdata.addr = (fetch_state == FetchWaitResp && fetch_inst_mem_rvalid) ? fetch_req_vaddr : fetch_pc;
        fetch_fifo_wdata.bits = (fetch_state == FetchWaitResp && fetch_inst_mem_rvalid) ? icache_rsp_data : '0;
        fetch_fifo_wdata.expt = '0;
        if (fetch_state == FetchFault && fetch_fifo_wready) begin
            fetch_fifo_wdata.addr = fetch_req_vaddr;
            fetch_fifo_wdata.expt = fetch_fault_expt;
        end else if (fetch_state == FetchIdle && !need_translate && !core_if.is_hazard && fetch_fifo_wready && !fetch_pmp_allow) begin
            fetch_fifo_wdata.expt.valid = 1'b1;
            fetch_fifo_wdata.expt.cause = INSTRUCTION_ACCESS_FAULT;
            fetch_fifo_wdata.expt.value = fetch_pc;
        end
    end

    // fetch_pc / requested レジスタ
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            fetch_pc         <= INITIAL_PC;
            fetch_req_vaddr  <= '0;
            fetch_req_paddr  <= '0;
            fetch_fault_expt <= '0;
            fetch_mem_owner  <= FetchMemOwnerNone;
            fetch_state      <= FetchIdle;
        end else begin
            if (fetch_translation_mem_ready) begin
                fetch_mem_owner <= FetchMemOwnerPtw;
            end else if (icache_mem_ready) begin
                fetch_mem_owner <= FetchMemOwnerIcache;
            end else if (mem_if.rvalid) begin
                fetch_mem_owner <= FetchMemOwnerNone;
            end

            if (core_if.is_hazard) begin
                fetch_pc         <= {core_if.next_pc[XLEN-1:3], 3'b000};
                fetch_req_vaddr  <= '0;
                fetch_req_paddr  <= '0;
                fetch_fault_expt <= '0;
                fetch_state      <= FetchIdle;
            end else begin
                unique case (fetch_state)
                    FetchIdle: begin
                        if (fetch_fifo_wready) begin
                            if (need_translate) begin
                                if (fetch_translation_req_ready) begin
                                    fetch_req_vaddr <= fetch_pc;
                                    if ($test$plusargs("TRACE_FETCH")) begin
                                        $display("[FETCH] translate va=%h priv=%0d satp=%h", fetch_pc, priv_mode, satp);
                                    end
                                    fetch_state <= FetchTranslate;
                                end
                            end else if (!fetch_pmp_allow) begin
                                if ($test$plusargs("TRACE_FETCH")) begin
                                    $display("[FETCH] pmp fault physical pc=%h", fetch_pc);
                                end
                                fetch_pc <= fetch_pc + 2;
                            end else if (fetch_inst_mem_fire) begin
                                if ($test$plusargs("TRACE_FETCH")) begin
                                    $display("[FETCH] request physical pc=%h", fetch_pc);
                                end
                                fetch_req_vaddr <= fetch_pc;
                                fetch_req_paddr <= fetch_pc;
                                fetch_pc <= fetch_pc + 8;
                                fetch_state <= FetchWaitResp;
                            end
                        end
                    end

                    FetchTranslate: begin
                        if (fetch_translation_rsp_valid) begin
                            if (fetch_translation_fault) begin
                                if ($test$plusargs("TRACE_FETCH")) begin
                                    $display("[FETCH] ptw fault va=%h cause=%0d detail=%0d value=%h",
                                        fetch_req_vaddr, fetch_translation_fault_cause, fetch_translation_fault_detail, fetch_translation_fault_value);
                                end
                                fetch_fault_expt.valid <= 1'b1;
                                fetch_fault_expt.cause <= fetch_translation_fault_cause;
                                fetch_fault_expt.value <= fetch_translation_fault_value;
                                fetch_pc <= fetch_pc + 2;
                                fetch_state <= FetchFault;
                            end else begin
                                if ($test$plusargs("TRACE_FETCH")) begin
                                    $display("[FETCH] ptw ok va=%h pa=%h", fetch_req_vaddr, fetch_translation_pa);
                                end
                                fetch_req_paddr <= fetch_translation_pa;
                                fetch_state <= FetchAccess;
                            end
                        end
                    end

                    FetchAccess: begin
                        if (!fetch_pmp_allow) begin
                            if ($test$plusargs("TRACE_FETCH")) begin
                                $display("[FETCH] pmp fault translated va=%h pa=%h", fetch_req_vaddr, fetch_req_paddr);
                            end
                            fetch_fault_expt.valid <= 1'b1;
                            fetch_fault_expt.cause <= INSTRUCTION_ACCESS_FAULT;
                            fetch_fault_expt.value <= fetch_req_vaddr;
                            fetch_pc <= fetch_pc + 2;
                            fetch_state <= FetchFault;
                        end else if (fetch_inst_mem_fire) begin
                            if ($test$plusargs("TRACE_FETCH")) begin
                                $display("[FETCH] request translated va=%h pa=%h", fetch_req_vaddr, fetch_req_paddr);
                            end
                            fetch_pc <= fetch_pc + 8;
                            fetch_state <= FetchWaitResp;
                        end
                    end

                    FetchWaitResp: begin
                        if (fetch_inst_mem_rvalid) begin
                            if ($test$plusargs("TRACE_FETCH")) begin
                                $display("[FETCH] response va=%h data=%h", fetch_req_vaddr, icache_rsp_data);
                            end
                            fetch_state <= FetchIdle;
                        end
                    end

                    FetchFault: begin
                        if (fetch_fifo_wready) begin
                            fetch_fault_expt <= '0;
                            fetch_state <= FetchIdle;
                        end
                    end

                    default: fetch_state <= FetchIdle;
                endcase
            end
        end
    end

endmodule
