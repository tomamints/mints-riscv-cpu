import eei::*;
import util::*;

`ifndef SVCPU_DCACHE_STORE_BUFFER_DEPTH
`define SVCPU_DCACHE_STORE_BUFFER_DEPTH 4
`endif

`ifndef SVCPU_DCACHE_LINE_COUNT
`define SVCPU_DCACHE_LINE_COUNT 128
`endif

`ifndef SVCPU_DCACHE_WRITE_BACK
`define SVCPU_DCACHE_WRITE_BACK 0
`endif

`ifndef SVCPU_DCACHE_DATA_RAM_STYLE
`define SVCPU_DCACHE_DATA_RAM_STYLE 0
`endif

`ifndef SVCPU_ICACHE_LINE_COUNT
`define SVCPU_ICACHE_LINE_COUNT 128
`endif
`ifndef SVCPU_ICACHE_DATA_RAM_STYLE
`define SVCPU_ICACHE_DATA_RAM_STYLE 0
`endif

module core_top #(
    parameter bit    RAM_FILEPATH_IS_ENV = 1,
    parameter string RAM_FILEPATH        = "RAM_FILE_PATH",
    parameter bit    ROM_FILEPATH_IS_ENV = 1,
    parameter string ROM_FILEPATH        = "ROM_FILE_PATH",
    parameter int unsigned DCACHE_LINE_COUNT = `SVCPU_DCACHE_LINE_COUNT,
    parameter int unsigned DCACHE_STORE_BUFFER_DEPTH = `SVCPU_DCACHE_STORE_BUFFER_DEPTH,
    parameter bit DCACHE_WRITE_BACK = `SVCPU_DCACHE_WRITE_BACK,
    parameter int unsigned DCACHE_DATA_RAM_STYLE = `SVCPU_DCACHE_DATA_RAM_STYLE,
    parameter int unsigned ICACHE_LINE_COUNT = `SVCPU_ICACHE_LINE_COUNT,
    parameter int unsigned ICACHE_DATA_RAM_STYLE = `SVCPU_ICACHE_DATA_RAM_STYLE
) (
`ifdef TEST_MODE
    output logic test_success,
`endif
    input  logic clk,
`ifdef SVCPU_PHYSICAL_UART
    input  logic uart_rx_i,
    output logic uart_tx_o,
    output logic uart_tx_overflow_o,
    output logic uart_rx_overrun_o,
`endif
    input  logic rst,
    input  Addr  MMAP_DBG_ADDR,
    output UIntX led

`ifdef SVCPU_WHISPER_LOCKSTEP
    ,
    output logic        retire_valid,
    output Addr         retire_pc,
    output Inst         retire_inst,
    output PrivMode     retire_priv,

    output logic        retire_rd_we,
    output logic [4:0]  retire_rd_addr,
    output UIntX        retire_rd_data,

    output logic        retire_mem_valid,
    output logic        retire_mem_write,
    output Addr         retire_mem_addr,
    output Addr         retire_mem_pa,
    output logic [7:0]  retire_mem_mask,
    output UIntX        retire_mem_data,

    output logic        lockstep_mtip,
    output logic        lockstep_interrupt_trap_taken,
    output CsrCause     lockstep_interrupt_cause,
    output Addr         lockstep_interrupt_pc,
    output Inst         lockstep_interrupt_inst,
    output logic        lockstep_exception_trap_taken,
    output CsrCause     lockstep_exception_cause,
    output UIntX        lockstep_exception_value,
    output Addr         lockstep_exception_pc,
    output Inst         lockstep_exception_inst,
    output logic        lockstep_mtip_trap_taken,
    output logic        lockstep_uart_tx_valid,
    output logic [7:0]  lockstep_uart_tx_char,

    output logic        lockstep_debug_id_valid,
    output Addr         lockstep_debug_id_pc,
    output logic        lockstep_debug_ex_valid,
    output Addr         lockstep_debug_ex_pc,
    output logic        lockstep_debug_ex_stall,
    output logic        lockstep_debug_mem_valid,
    output Addr         lockstep_debug_mem_pc,
    output logic        lockstep_debug_mem_stall,
    output logic        lockstep_debug_wb_valid,
    output Addr         lockstep_debug_wb_pc,
    output logic [2:0]  lockstep_debug_memu_state,
    output logic        lockstep_debug_memu_is_new,
    output logic        lockstep_debug_memu_req_wen,
    output logic        lockstep_debug_memu_need_translate,
    output logic        lockstep_debug_memu_translation_req_valid,
    output logic        lockstep_debug_memu_translation_req_ready,
    output logic        lockstep_debug_memu_translation_rsp_valid,
    output logic        lockstep_debug_memu_translation_mem_valid,
    output logic        lockstep_debug_memu_data_mem_rvalid,
    output logic        lockstep_debug_memu_bus_valid,
    output logic        lockstep_debug_memu_bus_ready,
    output logic        lockstep_debug_memu_bus_rvalid,
    output logic        lockstep_debug_memu_fast_load_req,
    output logic        lockstep_debug_memu_fast_load_valid,
    output logic        lockstep_debug_memu_fast_store_req,
    output logic        lockstep_debug_memu_fast_store_valid,
    output logic        lockstep_debug_i_valid,
    output logic        lockstep_debug_i_ready,
    output logic        lockstep_debug_i_rvalid,
    output logic        lockstep_debug_d_valid,
    output logic        lockstep_debug_d_ready,
    output logic        lockstep_debug_d_rvalid,
    output logic        lockstep_debug_dcache_flush_busy,
    output logic [2:0]  lockstep_debug_dcache_state,
    output logic [7:0]  lockstep_debug_dcache_store_buffer_count,
    output logic        lockstep_debug_dcache_store_buffer_issue_valid,
    output logic        lockstep_debug_dcache_store_buffer_issue_fire,
    output logic        lockstep_debug_dcache_store_buffer_empty,
    output logic        lockstep_debug_dcache_cpu_cacheable,
    output logic        lockstep_debug_dcache_cache_hit,
    output logic        lockstep_debug_dcache_cpu_store_buffer_overlap,
    output logic        lockstep_debug_dcache_load_can_bypass_store_buffer,
    output logic        lockstep_debug_dcache_rsp_valid,
    output logic        lockstep_debug_dcache_flush_active,
    output logic        lockstep_debug_dcache_mem_valid,
    output logic        lockstep_debug_dcache_mem_ready,
    output logic        lockstep_debug_dcache_mem_rvalid,
    output logic [3:0]  lockstep_debug_amou_state,
    output logic        lockstep_debug_amou_slave_valid,
    output logic        lockstep_debug_amou_slave_ready,
    output logic        lockstep_debug_amou_slave_rvalid,
    output logic        lockstep_debug_amou_master_valid,
    output logic        lockstep_debug_amou_master_ready,
    output logic        lockstep_debug_amou_master_rvalid,
    output logic        lockstep_debug_amou_slave_saved_valid,
    output logic        lockstep_debug_mmio_valid,
    output logic        lockstep_debug_mmio_ready,
    output logic        lockstep_debug_mmio_rvalid
`endif
);

    // Capacity profile check (C3 M3c): an explicit SVCPU_RAM_SIZE_BYTES must be
    // non-zero, a power of two, a multiple of 8 and not overflow BEGIN + SIZE.
    // An invalid size instantiates a module that does not exist, so elaboration
    // fails in both simulation and synthesis. Absent in the legacy profile.
`ifdef SVCPU_RAM_SIZE_BYTES
    if (!RAM_SIZE_VALID) begin : g_invalid_ram_size
        svcpu_error_invalid_ram_size_profile invalid_ram_size_profile ();
    end
`endif

    // アドレスをデータ単位に変換
    function automatic logic [RAM_ADDR_WIDTH-1:0] addr_to_ramaddr(
        input logic [XLEN-1:0] addr
    );
        return addr[$clog2(RAM_DATA_WIDTH / 8) +: RAM_ADDR_WIDTH];
    endfunction

    function automatic logic [ROM_ADDR_WIDTH-1:0] addr_to_romaddr(
        input logic [XLEN-1:0] addr
    );
        return addr[$clog2(ROM_DATA_WIDTH / 8) +: ROM_ADDR_WIDTH];
    endfunction

    // MMIOクロスバー
    Membus mmio_membus();
    Membus mmio_ram_membus();
    Membus mmio_rom_membus();
    Membus mmio_dma_membus();
    Membus dbg_membus();
    Membus aclint_membus();
    Membus plic_membus();
    Membus uart_membus();
    Membus dma_ram_membus();

    aclint_if aclint_core_bus();

`ifdef SVCPU_WHISPER_LOCKSTEP
    assign lockstep_mtip = aclint_core_bus.mtip;
`endif

    //arbiter出力用のバズ
    Membus arb_ram_membus();


    // 物理メモリIF（word index）
    membus_if #(
        .DATA_WIDTH(RAM_DATA_WIDTH),
        .ADDR_WIDTH(RAM_ADDR_WIDTH)
    ) ram_membus();

    membus_if #(
        .DATA_WIDTH(ROM_DATA_WIDTH),
        .ADDR_WIDTH(ROM_ADDR_WIDTH)
    ) rom_membus();


    // お手本（Veryl）命名に統一

    Membus #(
        .DATA_WIDTH(MEMBUS_DATA_WIDTH),
        .ADDR_WIDTH(XLEN)
    ) i_membus();

    core_inst_if #(
    ) i_membus_core();

    Membus #(
        .DATA_WIDTH(MEMBUS_DATA_WIDTH),
        .ADDR_WIDTH(XLEN)
    ) d_membus();

    core_data_if #(
    ) d_membus_core();

    core_data_if #(
    ) dcache_membus_core();

    PrivMode pmp_priv_mode;
    UIntX pmpcfg0_fetch_value;
    PmpRegion [7:0] pmp_regions_fetch_value;
    UIntX satp_fetch_value;
    logic translation_flush_fetch_value;
    logic dcache_flush_busy;
    logic [2:0] dcache_debug_state;
    logic [7:0] dcache_debug_store_buffer_count;
    logic dcache_debug_store_buffer_issue_valid;
    logic dcache_debug_store_buffer_issue_fire;
    logic dcache_debug_store_buffer_empty;
    logic dcache_debug_cpu_cacheable;
    logic dcache_debug_cache_hit;
    logic dcache_debug_cpu_store_buffer_overlap;
    logic dcache_debug_load_can_bypass_store_buffer;
    logic dcache_debug_rsp_valid;
    logic dcache_debug_flush_active;
    logic [3:0] amou_debug_state;
    logic amou_idle;
    // fence.i completion (WB0): every older store has been performed at RAM.
    // mmio_controller releases only on the device response and a write
    // response means "performed", so an idle amounit with an empty store
    // buffer and an idle D-cache leaves nothing outstanding below the core.
    logic dmem_quiescent;
    logic fence_i_drain;   // core: fence.i waiting in MEM for dmem_quiescent
    logic amou_debug_slave_valid;
    logic amou_debug_slave_ready;
    logic amou_debug_slave_rvalid;
    logic amou_debug_master_valid;
    logic amou_debug_master_ready;
    logic amou_debug_master_rvalid;
    logic amou_debug_slave_saved_valid;
    logic sstatus_sum_fetch_value;
    logic sstatus_mxr_fetch_value;
    logic uart_irq;
    logic uart_tx_char_valid;
    logic [7:0] uart_tx_char;
    logic plic_meip;
    logic plic_seip;
    logic [PLIC_NUM_SOURCES:0] plic_source_irq;

    logic memarb_last_i;
    logic d_membus_low_priority;
    logic dcache_mem_low_priority;
    logic amo_commit_valid;
    UIntX amo_commit_wdata;
    logic amo_reservation_clear;
    logic memarb_select_d;
    logic memarb_issue_is_i;
    UInt64 perf_memarb_i_grant_count;
    UInt64 perf_memarb_d_grant_count;
    UInt64 perf_memarb_d_low_grant_count;
    UInt64 perf_memarb_d_low_defer_count;
    UInt64 perf_memarb_i_wait_cycle;
    UInt64 perf_memarb_d_high_wait_cycle;
    UInt64 perf_memarb_d_low_wait_cycle;

    always_comb begin
        plic_source_irq = '0;
        plic_source_irq[PLIC_UART_IRQ] = uart_irq;
    end

    always_ff @(posedge clk) begin
        // -----------------------------------------------------------
        // Debug membus は常に ready
        // -----------------------------------------------------------
        dbg_membus.ready  <= 1'b1;
        dbg_membus.rvalid <= dbg_membus.valid;

        // ① Debug I/O (0x4000_0000) : printf / exit-flag
        if (dbg_membus.valid) begin
            if (dbg_membus.wen) begin
                // (A) printf 出力（上位20bitが 01010h）
                if (dbg_membus.wdata[MEMBUS_DATA_WIDTH-1 -: 20] == 20'h01010) begin
                    $write("%c", dbg_membus.wdata[7:0]);
                    $fflush();
                end
                // (B) 自作終了フラグ（LSB==1） ※このケースでは 0x01010 は立っていない前提
                else if (dbg_membus.wdata[0] == 1'b1) begin
                    `ifdef TEST_MODE
                        test_success <= (dbg_membus.wdata == 64'h1);
                    `endif

                    if (dbg_membus.wdata == 64'h1)
                        $display("test success!");
                    else begin
                        $display("test failed!");
                        $error("wdata : %h", dbg_membus.wdata);
                    end
                    $finish();
                end
            end else begin
                `ifdef ENABLE_DEBUG_INPUT
                    dbg_membus.rdata <= util::get_input();
                `endif
            end
        end
    end

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            perf_memarb_i_grant_count <= '0;
            perf_memarb_d_grant_count <= '0;
            perf_memarb_d_low_grant_count <= '0;
            perf_memarb_d_low_defer_count <= '0;
            perf_memarb_i_wait_cycle <= '0;
            perf_memarb_d_high_wait_cycle <= '0;
            perf_memarb_d_low_wait_cycle <= '0;
        end else begin
            if (mmio_membus.valid && mmio_membus.ready) begin
                if (memarb_issue_is_i) begin
                    perf_memarb_i_grant_count <= perf_memarb_i_grant_count + UInt64'(1);
                end else begin
                    perf_memarb_d_grant_count <= perf_memarb_d_grant_count + UInt64'(1);
                    if (d_membus_low_priority) begin
                        perf_memarb_d_low_grant_count <= perf_memarb_d_low_grant_count + UInt64'(1);
                    end
                end
            end
            if (i_membus.valid && d_membus.valid && d_membus_low_priority) begin
                perf_memarb_d_low_defer_count <= perf_memarb_d_low_defer_count + UInt64'(1);
            end
            if (i_membus.valid && !i_membus.ready) begin
                perf_memarb_i_wait_cycle <= perf_memarb_i_wait_cycle + UInt64'(1);
            end
            if (d_membus.valid && !d_membus.ready) begin
                if (d_membus_low_priority) begin
                    perf_memarb_d_low_wait_cycle <= perf_memarb_d_low_wait_cycle + UInt64'(1);
                end else begin
                    perf_memarb_d_high_wait_cycle <= perf_memarb_d_high_wait_cycle + UInt64'(1);
                end
            end
        end
    end





    // mmio_controller 調停（I/D のどちらの応答か保持）
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            memarb_last_i     <= 1'b0;
        end else if (mmio_membus.ready && mmio_membus.valid) begin
            memarb_last_i     <= memarb_issue_is_i;
        end
    end

    // I/D → MMIO（要求多重化 & 応答戻し）
    always_comb begin
        // While fence.i waits for the drain, D low priority is ignored so that
        // instruction prefetch cannot starve the store-buffer drain.
        memarb_select_d = d_membus.valid && !(d_membus_low_priority && i_membus.valid && !fence_i_drain);
        memarb_issue_is_i = i_membus.valid && !memarb_select_d;

        i_membus.ready  = mmio_membus.ready && !memarb_select_d;
        i_membus.rvalid = mmio_membus.rvalid && memarb_last_i;
        i_membus.rdata  = mmio_membus.rdata;

        d_membus.ready  = mmio_membus.ready && memarb_select_d;
        d_membus.rvalid = mmio_membus.rvalid && !memarb_last_i;
        d_membus.rdata  = mmio_membus.rdata;

        mmio_membus.valid = i_membus.valid | d_membus.valid;
        if (memarb_select_d) begin
            mmio_membus.addr  = d_membus.addr;
            mmio_membus.wen   = d_membus.wen;
            mmio_membus.wdata = d_membus.wdata;
            mmio_membus.wmask = d_membus.wmask;
        end else begin
            mmio_membus.addr  = i_membus.addr;
            mmio_membus.wen   = 1'b0;   // 命令フェッチは常に読み
            mmio_membus.wdata = 'x;
            mmio_membus.wmask = 'x;
        end
    end

    // Optional simulation-only RAM latency injection (C3 M1, default off).
    // Sits on the 64-bit byte-offset Membus, upstream of addr_to_ramaddr.
`ifdef SVCPU_RAM_LATENCY_SHIM
    Membus shim_ram_membus();
    membus_latency_shim ram_latency_shim (
        .clk  (clk),
        .rst  (rst),
        .up   (arb_ram_membus),
        .down (shim_ram_membus)
    );
`define SVCPU_RAM_CONV_MEMBUS shim_ram_membus
    // Sim-only observer (no functional effect), enabled by +RAM_SHIM_TRACE_FENCE:
    // prints the cycle at which the I-side fetch_invalidate (fence.i) is consumed,
    // on the shim trace time base, plus the core cycle counter for cross-checking.
    bit ram_shim_trace_fence;
    initial ram_shim_trace_fence = $test$plusargs("RAM_SHIM_TRACE_FENCE");
    always @(posedge clk) begin
        if (ram_shim_trace_fence && rst && i_membus_core.fetch_invalidate)
            $display("RAM_SHIM_FENCE cyc=%0d core_cycle=%0d pc=%016h",
                     ram_latency_shim.trace_cyc, c.debug_cycle, c.mems_pc);
    end
`else
`define SVCPU_RAM_CONV_MEMBUS arb_ram_membus
`endif

`ifdef SVCPU_RAM_SDRAM_MODEL
    // Simulation RAM backend through the FPGA SDRAM path (C3 M3b):
    //   RAM Membus -> membus_sdram_adapter -> sdram_bridge64 -> sdram_native16
    //   (CLK_HZ 20 MHz profile) -> sdram_cycle_model16 (clock-sampled model).
    // A preloader owns the adapter until the RAM image is written; meanwhile the
    // CPU RAM port gets no ready (the CPU waits at its first RAM access; no reset
    // hold, no warm-reset pulse). Cold reset of the SDRAM path = rst.
    Membus preload_membus();
    Membus sdram_up_membus();
    logic sdram_preload_done;
    sdram_preloader #(
        .FILEPATH_IS_ENV(RAM_FILEPATH_IS_ENV),
        .FILEPATH       (RAM_FILEPATH)
    ) sdram_preload (
        .clk  (clk),
        .rst  (rst),
        .done (sdram_preload_done),
        .bus  (preload_membus)
    );
    always_comb begin
        if (sdram_preload_done) begin
            sdram_up_membus.valid = `SVCPU_RAM_CONV_MEMBUS.valid;
            sdram_up_membus.addr  = `SVCPU_RAM_CONV_MEMBUS.addr;
            sdram_up_membus.wen   = `SVCPU_RAM_CONV_MEMBUS.wen;
            sdram_up_membus.wdata = `SVCPU_RAM_CONV_MEMBUS.wdata;
            sdram_up_membus.wmask = `SVCPU_RAM_CONV_MEMBUS.wmask;
        end else begin
            sdram_up_membus.valid = preload_membus.valid;
            sdram_up_membus.addr  = preload_membus.addr;
            sdram_up_membus.wen   = preload_membus.wen;
            sdram_up_membus.wdata = preload_membus.wdata;
            sdram_up_membus.wmask = preload_membus.wmask;
        end
        `SVCPU_RAM_CONV_MEMBUS.ready  = sdram_preload_done && sdram_up_membus.ready;
        `SVCPU_RAM_CONV_MEMBUS.rvalid = sdram_preload_done && sdram_up_membus.rvalid;
        `SVCPU_RAM_CONV_MEMBUS.rdata  = sdram_up_membus.rdata;
        preload_membus.ready  = !sdram_preload_done && sdram_up_membus.ready;
        preload_membus.rvalid = !sdram_preload_done && sdram_up_membus.rvalid;
        preload_membus.rdata  = sdram_up_membus.rdata;
    end

    logic        sdram_req_valid, sdram_req_ready, sdram_req_write, sdram_rsp_valid, sdram_rsp_error;
    logic [63:0] sdram_req_addr, sdram_req_wdata, sdram_rsp_data;
    logic [7:0]  sdram_req_be;
    logic        sdram_fault, sdram_fault_seen, sdram_fault_wen;
    logic [1:0]  sdram_fault_kind;
    logic [63:0] sdram_fault_offset, sdram_fault_abs;
    membus_sdram_adapter sdram_adapter (
        .clk(clk), .rst_n(rst), .soft_reset(1'b0), .up(sdram_up_membus),
        .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req_addr(sdram_req_addr),
        .req_write(sdram_req_write), .req_wdata(sdram_req_wdata), .req_be(sdram_req_be),
        .rsp_valid(sdram_rsp_valid), .rsp_data(sdram_rsp_data), .rsp_error(sdram_rsp_error),
        .fault(sdram_fault), .fault_seen(sdram_fault_seen), .fault_kind(sdram_fault_kind),
        .fault_offset(sdram_fault_offset), .fault_abs(sdram_fault_abs), .fault_wen(sdram_fault_wen)
    );
    logic        sdram_nv, sdram_nready, sdram_nwrite, sdram_nrvalid, sdram_oe;
    logic [24:0] sdram_naddr;
    logic [15:0] sdram_nwdata, sdram_nrdata, sdram_dq_out, sdram_dq_in;
    logic [1:0]  sdram_nbe, sdram_ba, sdram_dqm;
    logic [12:0] sdram_a;
    logic        sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    sdram_bridge64 sdram_bridge (
        .clk(clk), .rst_n(rst), .soft_reset(1'b0),
        .req_valid(sdram_req_valid), .req_ready(sdram_req_ready), .req_addr(sdram_req_addr),
        .req_write(sdram_req_write), .req_wdata(sdram_req_wdata), .req_be(sdram_req_be),
        .rsp_valid(sdram_rsp_valid), .rsp_data(sdram_rsp_data), .rsp_error(sdram_rsp_error),
        .native_valid(sdram_nv), .native_ready(sdram_nready), .native_addr(sdram_naddr),
        .native_write(sdram_nwrite), .native_wdata(sdram_nwdata), .native_be(sdram_nbe),
        .native_rsp_valid(sdram_nrvalid), .native_rsp_data(sdram_nrdata)
    );
    sdram_native16 #(.CLK_HZ(20_000_000)) sdram_ctrl (
        .clk(clk), .rst_n(rst), .soft_reset(1'b0),
        .req_valid(sdram_nv), .req_ready(sdram_nready), .req_addr(sdram_naddr),
        .req_write(sdram_nwrite), .req_wdata(sdram_nwdata), .req_be(sdram_nbe),
        .rsp_valid(sdram_nrvalid), .rsp_data(sdram_nrdata), .init_done(),
        .dram_addr(sdram_a), .dram_ba(sdram_ba), .dram_dqm(sdram_dqm), .dram_cke(sdram_cke),
        .dram_cs_n(sdram_cs_n), .dram_ras_n(sdram_ras_n), .dram_cas_n(sdram_cas_n),
        .dram_we_n(sdram_we_n), .dq_in(sdram_dq_in), .dq_out(sdram_dq_out), .dq_oe(sdram_oe)
    );
    sdram_cycle_model16 #(.CLK_HZ(20_000_000), .UNWRITTEN(16'h0000)) sdram_model (
        .clk(clk), .rst_n(rst), .a(sdram_a), .ba(sdram_ba), .dqm(sdram_dqm), .cke(sdram_cke),
        .csn(sdram_cs_n), .rasn(sdram_ras_n), .casn(sdram_cas_n), .wen(sdram_we_n),
        .oe(sdram_oe), .dout(sdram_dq_out), .din(sdram_dq_in)
    );
`else
    // arbiter後のMembus → RAM(=membus_if) 変換
    always_comb begin
        ram_membus.valid = `SVCPU_RAM_CONV_MEMBUS.valid;
        `SVCPU_RAM_CONV_MEMBUS.ready = ram_membus.ready;

        ram_membus.addr  = addr_to_ramaddr(`SVCPU_RAM_CONV_MEMBUS.addr);
        ram_membus.wen   = `SVCPU_RAM_CONV_MEMBUS.wen;
        ram_membus.wdata = `SVCPU_RAM_CONV_MEMBUS.wdata;
        ram_membus.wmask = `SVCPU_RAM_CONV_MEMBUS.wmask;

        `SVCPU_RAM_CONV_MEMBUS.rvalid = ram_membus.rvalid;
        `SVCPU_RAM_CONV_MEMBUS.rdata  = ram_membus.rdata;
    end
`endif
`undef SVCPU_RAM_CONV_MEMBUS



    // mmio <> ROM (read-only)
    always_comb begin
        rom_membus.valid       = mmio_rom_membus.valid;
        mmio_rom_membus.ready  = rom_membus.ready;
        rom_membus.addr        = addr_to_romaddr(mmio_rom_membus.addr);
        rom_membus.wen         = 1'b0;
        rom_membus.wdata       = '0;
        rom_membus.wmask       = '0;
        mmio_rom_membus.rvalid = rom_membus.rvalid;
        mmio_rom_membus.rdata  = rom_membus.rdata;
    end


    // RAM/ROM 実体
`ifndef SVCPU_RAM_SDRAM_MODEL
    memory #(
        .DATA_WIDTH     (RAM_DATA_WIDTH),
        .ADDR_WIDTH     (RAM_ADDR_WIDTH),
        .FILEPATH_IS_ENV(RAM_FILEPATH_IS_ENV),
        .FILEPATH       (RAM_FILEPATH)
    ) ram (
        .clk    (clk),
        .rst    (rst),
        .membus (ram_membus)
    );
`endif

    memory #(
        .DATA_WIDTH     (ROM_DATA_WIDTH),
        .ADDR_WIDTH     (ROM_ADDR_WIDTH),
        .FILEPATH_IS_ENV(ROM_FILEPATH_IS_ENV),
        .FILEPATH       (ROM_FILEPATH)
    ) rom (
        .clk    (clk),
        .rst    (rst),
        .membus (rom_membus)
    );

    aclint_memory aclintm (
        .clk    (clk),
        .rst    (rst),
        .membus (aclint_membus),
        .aclint (aclint_core_bus)
    );


    // MMIO コントローラ
    mmio_controller mmioc (
        .clk         (clk),
        .rst         (rst),
        .DBG_ADDR    (MMAP_DBG_ADDR),
        .req_core    (mmio_membus),
        .ram_membus  (mmio_ram_membus),
        .rom_membus  (mmio_rom_membus),
        .dbg_membus  (dbg_membus),
        .aclint_membus  (aclint_membus),
        .plic_membus (plic_membus),
        .dma_membus  (mmio_dma_membus),
        .uart_membus (uart_membus)
    );

    dcache #(
        .LINE_COUNT(DCACHE_LINE_COUNT),
        .STORE_BUFFER_DEPTH(DCACHE_STORE_BUFFER_DEPTH),
        .WRITE_BACK(DCACHE_WRITE_BACK),
        .DATA_RAM_STYLE(DCACHE_DATA_RAM_STYLE)
    ) dcache0 (
        .clk        (clk),
        .rst        (rst),
        .invalidate (translation_flush_fetch_value),
        .flush_busy (dcache_flush_busy),
        .mem_low_priority(dcache_mem_low_priority),
        .debug_state(dcache_debug_state),
        .debug_store_buffer_count(dcache_debug_store_buffer_count),
        .debug_store_buffer_issue_valid(dcache_debug_store_buffer_issue_valid),
        .debug_store_buffer_issue_fire(dcache_debug_store_buffer_issue_fire),
        .debug_store_buffer_empty(dcache_debug_store_buffer_empty),
        .debug_cpu_cacheable(dcache_debug_cpu_cacheable),
        .debug_cache_hit(dcache_debug_cache_hit),
        .debug_cpu_store_buffer_overlap(dcache_debug_cpu_store_buffer_overlap),
        .debug_cacheable_load_can_bypass_store_buffer(dcache_debug_load_can_bypass_store_buffer),
        .debug_rsp_valid(dcache_debug_rsp_valid),
        .debug_flush_active(dcache_debug_flush_active),
        .cpu        (d_membus_core),
        .mem        (dcache_membus_core)
    );

    amounit amou (
        .clk    (clk),
        .rst    (rst),
        .reservation_clear(amo_reservation_clear),
        .slave_low_priority(dcache_mem_low_priority),
        .master_low_priority(d_membus_low_priority),
        .slave  (dcache_membus_core),
        .master (d_membus),
        .amo_commit_valid(amo_commit_valid),
        .amo_commit_wdata(amo_commit_wdata),
        .debug_state(amou_debug_state),
        .idle(amou_idle),
        .debug_slave_valid(amou_debug_slave_valid),
        .debug_slave_ready(amou_debug_slave_ready),
        .debug_slave_rvalid(amou_debug_slave_rvalid),
        .debug_master_valid(amou_debug_master_valid),
        .debug_master_ready(amou_debug_master_ready),
        .debug_master_rvalid(amou_debug_master_rvalid),
        .debug_slave_saved_valid(amou_debug_slave_saved_valid)
    );

    assign dmem_quiescent = dcache_debug_store_buffer_empty &&
                            (dcache_debug_state == 3'd0) &&   // dcache Idle
                            amou_idle;
`ifndef SYNTHESIS
    initial if (DCACHE_WRITE_BACK)
        $warning("fence.i completion covers WRITE_BACK=0 only (no dirty-line clean)");
`endif

    dma u_dma(
        .clk (clk),
        .rst (rst),
        .mmio(mmio_dma_membus),
        .ram(dma_ram_membus)
    );

`ifdef SVCPU_PHYSICAL_UART
    uart16550_serial #(.CLK_HZ(20_000_000), .REF_HZ(3_686_400)) uart0 (
        .clk(clk), .rst(rst), .membus(uart_membus), .irq(uart_irq),
        .rxd(uart_rx_i), .txd(uart_tx_o),
        .diag_tx_overflow(uart_tx_overflow_o), .diag_rx_overrun(uart_rx_overrun_o)
    );
    assign uart_tx_char_valid = 1'b0;
    assign uart_tx_char = '0;
`else
    uart_ns16550 uart0 (
        .clk           (clk),
        .rst           (rst),
        .membus        (uart_membus),
        .irq           (uart_irq),
        .tx_char_valid (uart_tx_char_valid),
        .tx_char       (uart_tx_char)
    );
`endif

    plic plic0 (
        .clk        (clk),
        .rst        (rst),
        .membus     (plic_membus),
        .source_irq (plic_source_irq),
        .meip       (plic_meip),
        .seip       (plic_seip)
    );

    ram_arbiter_cpu_prio ram_arb (
        .clk (clk),
        .rst (rst),
        .cpu (mmio_ram_membus),   // CPU側（MMIO経由RAM）
        .dma (dma_ram_membus),    // DMA側（DMAのRAM master）
        .out (arb_ram_membus)     // 統合後
    );



    inst_fetcher #(.ICACHE_LINE_COUNT(ICACHE_LINE_COUNT), .ICACHE_DATA_RAM_STYLE(ICACHE_DATA_RAM_STYLE)) fethcer (
        .clk       (clk),
        .rst       (rst),
        .priv_mode (pmp_priv_mode),
        .pmpcfg0   (pmpcfg0_fetch_value),
        .pmp_regions(pmp_regions_fetch_value),
        .satp      (satp_fetch_value),
        .sstatus_sum(sstatus_sum_fetch_value),
        .sstatus_mxr(sstatus_mxr_fetch_value),
        .translation_flush(translation_flush_fetch_value),
        .core_if   (i_membus_core),
        .mem_if    (i_membus)
    );

    // コア接続（Veryl命名に完全一致）
    core c (
        .clk      (clk),
        .rst      (rst),
        .i_membus (i_membus_core),
        .d_membus (d_membus_core),
        .amo_commit_valid(amo_commit_valid),
        .amo_commit_wdata(amo_commit_wdata),
        .led      (led),
        .amo_reservation_clear_o(amo_reservation_clear),

`ifdef SVCPU_WHISPER_LOCKSTEP
        .retire_valid_o    (retire_valid),
        .retire_pc_o       (retire_pc),
        .retire_inst_o     (retire_inst),
        .retire_priv_o     (retire_priv),

        .retire_rd_we_o    (retire_rd_we),
        .retire_rd_addr_o  (retire_rd_addr),
        .retire_rd_data_o  (retire_rd_data),

        .retire_mem_valid_o(retire_mem_valid),
        .retire_mem_write_o(retire_mem_write),
        .retire_mem_addr_o (retire_mem_addr),
        .retire_mem_pa_o   (retire_mem_pa),
        .retire_mem_mask_o (retire_mem_mask),
        .retire_mem_data_o (retire_mem_data),

        .lockstep_interrupt_trap_taken_o(lockstep_interrupt_trap_taken),
        .lockstep_interrupt_cause_o(lockstep_interrupt_cause),
        .lockstep_interrupt_pc_o(lockstep_interrupt_pc),
        .lockstep_interrupt_inst_o(lockstep_interrupt_inst),
        .lockstep_exception_trap_taken_o(lockstep_exception_trap_taken),
        .lockstep_exception_cause_o(lockstep_exception_cause),
        .lockstep_exception_value_o(lockstep_exception_value),
        .lockstep_exception_pc_o(lockstep_exception_pc),
        .lockstep_exception_inst_o(lockstep_exception_inst),
        .lockstep_mtip_trap_taken_o(lockstep_mtip_trap_taken),
        .lockstep_debug_id_valid_o(lockstep_debug_id_valid),
        .lockstep_debug_id_pc_o(lockstep_debug_id_pc),
        .lockstep_debug_ex_valid_o(lockstep_debug_ex_valid),
        .lockstep_debug_ex_pc_o(lockstep_debug_ex_pc),
        .lockstep_debug_ex_stall_o(lockstep_debug_ex_stall),
        .lockstep_debug_mem_valid_o(lockstep_debug_mem_valid),
        .lockstep_debug_mem_pc_o(lockstep_debug_mem_pc),
        .lockstep_debug_mem_stall_o(lockstep_debug_mem_stall),
        .lockstep_debug_wb_valid_o(lockstep_debug_wb_valid),
        .lockstep_debug_wb_pc_o(lockstep_debug_wb_pc),
        .lockstep_debug_memu_state_o(lockstep_debug_memu_state),
        .lockstep_debug_memu_is_new_o(lockstep_debug_memu_is_new),
        .lockstep_debug_memu_req_wen_o(lockstep_debug_memu_req_wen),
        .lockstep_debug_memu_need_translate_o(lockstep_debug_memu_need_translate),
        .lockstep_debug_memu_translation_req_valid_o(lockstep_debug_memu_translation_req_valid),
        .lockstep_debug_memu_translation_req_ready_o(lockstep_debug_memu_translation_req_ready),
        .lockstep_debug_memu_translation_rsp_valid_o(lockstep_debug_memu_translation_rsp_valid),
        .lockstep_debug_memu_translation_mem_valid_o(lockstep_debug_memu_translation_mem_valid),
        .lockstep_debug_memu_data_mem_rvalid_o(lockstep_debug_memu_data_mem_rvalid),
        .lockstep_debug_memu_bus_valid_o(lockstep_debug_memu_bus_valid),
        .lockstep_debug_memu_bus_ready_o(lockstep_debug_memu_bus_ready),
        .lockstep_debug_memu_bus_rvalid_o(lockstep_debug_memu_bus_rvalid),
        .lockstep_debug_memu_fast_load_req_o(lockstep_debug_memu_fast_load_req),
        .lockstep_debug_memu_fast_load_valid_o(lockstep_debug_memu_fast_load_valid),
        .lockstep_debug_memu_fast_store_req_o(lockstep_debug_memu_fast_store_req),
        .lockstep_debug_memu_fast_store_valid_o(lockstep_debug_memu_fast_store_valid),
`endif

        .pmp_priv_mode(pmp_priv_mode),
        .pmpcfg0_fetch_value(pmpcfg0_fetch_value),
        .pmp_regions_fetch_value(pmp_regions_fetch_value),
        .satp_fetch_value(satp_fetch_value),
        .translation_flush_fetch_value(translation_flush_fetch_value),
        .sstatus_sum_fetch_value(sstatus_sum_fetch_value),
        .sstatus_mxr_fetch_value(sstatus_mxr_fetch_value),
        .dcache_flush_busy(dcache_flush_busy),
        .dmem_quiescent(dmem_quiescent),
        .fence_i_drain(fence_i_drain),
        .external_meip(plic_meip),
        .external_seip(plic_seip),
        .aclint   (aclint_core_bus)
    );

`ifndef SYNTHESIS
    final begin
        if ($test$plusargs("PERF_SUMMARY")) begin
            $display("[PERF-MEMARB] i_grant=%0d d_grant=%0d d_low_grant=%0d d_low_defer=%0d",
                perf_memarb_i_grant_count,
                perf_memarb_d_grant_count,
                perf_memarb_d_low_grant_count,
                perf_memarb_d_low_defer_count);
            $display("[PERF-MEMARB-STALL] i_wait=%0d d_high_wait=%0d d_low_wait=%0d",
                perf_memarb_i_wait_cycle,
                perf_memarb_d_high_wait_cycle,
                perf_memarb_d_low_wait_cycle);
        end
    end
`endif

`ifdef SVCPU_WHISPER_LOCKSTEP
    assign lockstep_uart_tx_valid = uart_tx_char_valid;
    assign lockstep_uart_tx_char = uart_tx_char;
    assign lockstep_debug_i_valid = i_membus.valid;
    assign lockstep_debug_i_ready = i_membus.ready;
    assign lockstep_debug_i_rvalid = i_membus.rvalid;
    assign lockstep_debug_d_valid = d_membus.valid;
    assign lockstep_debug_d_ready = d_membus.ready;
    assign lockstep_debug_d_rvalid = d_membus.rvalid;
    assign lockstep_debug_dcache_flush_busy = dcache_flush_busy;
    assign lockstep_debug_dcache_state = dcache_debug_state;
    assign lockstep_debug_dcache_store_buffer_count = dcache_debug_store_buffer_count;
    assign lockstep_debug_dcache_store_buffer_issue_valid = dcache_debug_store_buffer_issue_valid;
    assign lockstep_debug_dcache_store_buffer_issue_fire = dcache_debug_store_buffer_issue_fire;
    assign lockstep_debug_dcache_store_buffer_empty = dcache_debug_store_buffer_empty;
    assign lockstep_debug_dcache_cpu_cacheable = dcache_debug_cpu_cacheable;
    assign lockstep_debug_dcache_cache_hit = dcache_debug_cache_hit;
    assign lockstep_debug_dcache_cpu_store_buffer_overlap = dcache_debug_cpu_store_buffer_overlap;
    assign lockstep_debug_dcache_load_can_bypass_store_buffer = dcache_debug_load_can_bypass_store_buffer;
    assign lockstep_debug_dcache_rsp_valid = dcache_debug_rsp_valid;
    assign lockstep_debug_dcache_flush_active = dcache_debug_flush_active;
    assign lockstep_debug_dcache_mem_valid = dcache_membus_core.valid;
    assign lockstep_debug_dcache_mem_ready = dcache_membus_core.ready;
    assign lockstep_debug_dcache_mem_rvalid = dcache_membus_core.rvalid;
    assign lockstep_debug_amou_state = amou_debug_state;
    assign lockstep_debug_amou_slave_valid = amou_debug_slave_valid;
    assign lockstep_debug_amou_slave_ready = amou_debug_slave_ready;
    assign lockstep_debug_amou_slave_rvalid = amou_debug_slave_rvalid;
    assign lockstep_debug_amou_master_valid = amou_debug_master_valid;
    assign lockstep_debug_amou_master_ready = amou_debug_master_ready;
    assign lockstep_debug_amou_master_rvalid = amou_debug_master_rvalid;
    assign lockstep_debug_amou_slave_saved_valid = amou_debug_slave_saved_valid;
    assign lockstep_debug_mmio_valid = mmio_membus.valid;
    assign lockstep_debug_mmio_ready = mmio_membus.ready;
    assign lockstep_debug_mmio_rvalid = mmio_membus.rvalid;
`endif

endmodule : core_top
