import eei::*;

// Analysis-only CPU resource probe built from the canonical sources (no
// private transforms): core + inst_fetcher (I-cache, predictor, PMP) + D-cache
// + amounit, with the instruction and data memory buses, timer/interrupt
// inputs and fence.i drain flag on virtual pins. It omits the SoC bus mux,
// peripherals, ROM, SDRAM path and loader, and makes no external timing claim,
// so a probe fit is NOT a complete-system fit.
module cpu_probe_top #(
    parameter int unsigned ICACHE_LINE_COUNT = 32,
    parameter int unsigned ICACHE_DATA_RAM_STYLE = 1,
    parameter int unsigned DCACHE_LINE_COUNT = 32,
    parameter int unsigned DCACHE_STORE_BUFFER_DEPTH = 4,
    parameter int unsigned DCACHE_DATA_RAM_STYLE = 1,
    parameter int unsigned BP_PHT_ENTRIES = 32,
    parameter int unsigned BP_BTB_ENTRIES = 8,
    parameter int unsigned BP_RAS_ENTRIES = 4
) (
    input  logic        clk,
    input  logic        v_rst,
    input  logic        v_i_ready, v_i_rvalid, v_d_ready, v_d_rvalid,
    input  logic [63:0] v_i_rdata, v_d_rdata, v_mtime,
    input  logic        v_msip, v_mtip, v_ssip, v_stip, v_meip, v_seip,
    output logic        v_i_valid, v_d_valid, v_d_wen, v_d_low, v_fence_i_drain,
    output logic [63:0] v_i_addr, v_d_addr, v_d_wdata, v_led,
    output logic [7:0]  v_d_wmask
);
    localparam bit DCACHE_WRITE_BACK = 1'b0;
    wire rst = v_rst;

    core_inst_if i_membus_core();
    core_data_if d_membus_core();
    core_data_if dcache_membus_core();
    Membus i_membus();
    Membus d_membus();
    aclint_if aclint_core_bus();

    logic d_membus_low_priority, dcache_mem_low_priority;
    logic amo_commit_valid, amo_reservation_clear;
    UIntX amo_commit_wdata;
    UIntX led;
    PrivMode pmp_priv_mode;
    UIntX pmpcfg0_fetch_value;
    PmpRegion [7:0] pmp_regions_fetch_value;
    UIntX satp_fetch_value;
    logic translation_flush_fetch_value;
    logic sstatus_sum_fetch_value, sstatus_mxr_fetch_value;
    logic dcache_flush_busy;
    logic [2:0] dcache_debug_state;
    logic dcache_debug_store_buffer_empty;
    logic amou_idle;
    logic dmem_quiescent, fence_i_drain;

    assign v_i_valid = i_membus.valid;
    assign v_i_addr = i_membus.addr;
    assign i_membus.ready = v_i_ready;
    assign i_membus.rvalid = v_i_rvalid;
    assign i_membus.rdata = v_i_rdata;
    assign v_d_valid = d_membus.valid;
    assign v_d_addr = d_membus.addr;
    assign v_d_wen = d_membus.wen;
    assign v_d_wdata = d_membus.wdata;
    assign v_d_wmask = d_membus.wmask;
    assign d_membus.ready = v_d_ready;
    assign d_membus.rvalid = v_d_rvalid;
    assign d_membus.rdata = v_d_rdata;
    assign v_d_low = d_membus_low_priority;
    assign v_fence_i_drain = fence_i_drain;
    assign v_led = led;
    assign aclint_core_bus.mtime = v_mtime;
    assign aclint_core_bus.msip = v_msip;
    assign aclint_core_bus.mtip = v_mtip;
    assign aclint_core_bus.setssip = v_ssip;
    assign aclint_core_bus.setstip = v_stip;

    dcache #(
        .LINE_COUNT(DCACHE_LINE_COUNT),
        .STORE_BUFFER_DEPTH(DCACHE_STORE_BUFFER_DEPTH),
        .WRITE_BACK(DCACHE_WRITE_BACK),
        .DATA_RAM_STYLE(DCACHE_DATA_RAM_STYLE)
    ) dcache0 (
        .clk(clk), .rst(rst),
        .invalidate(translation_flush_fetch_value),
        .flush_busy(dcache_flush_busy),
        .mem_low_priority(dcache_mem_low_priority),
        .debug_state(dcache_debug_state),
        .debug_store_buffer_count(),
        .debug_store_buffer_issue_valid(),
        .debug_store_buffer_issue_fire(),
        .debug_store_buffer_empty(dcache_debug_store_buffer_empty),
        .debug_cpu_cacheable(),
        .debug_cache_hit(),
        .debug_cpu_store_buffer_overlap(),
        .debug_cacheable_load_can_bypass_store_buffer(),
        .debug_rsp_valid(),
        .debug_flush_active(),
        .cpu(d_membus_core),
        .mem(dcache_membus_core)
    );

    amounit amou (
        .clk(clk), .rst(rst),
        .reservation_clear(amo_reservation_clear),
        .slave_low_priority(dcache_mem_low_priority),
        .master_low_priority(d_membus_low_priority),
        .slave(dcache_membus_core),
        .master(d_membus),
        .amo_commit_valid(amo_commit_valid),
        .amo_commit_wdata(amo_commit_wdata),
        .debug_state(),
        .idle(amou_idle),
        .debug_slave_valid(), .debug_slave_ready(), .debug_slave_rvalid(),
        .debug_master_valid(), .debug_master_ready(), .debug_master_rvalid(),
        .debug_slave_saved_valid()
    );

    // same completion condition as src/top.sv
    assign dmem_quiescent = dcache_debug_store_buffer_empty && (dcache_debug_state == 3'd0) && amou_idle;

    inst_fetcher #(
        .ICACHE_LINE_COUNT(ICACHE_LINE_COUNT),
        .ICACHE_DATA_RAM_STYLE(ICACHE_DATA_RAM_STYLE),
        .BP_PHT_ENTRIES(BP_PHT_ENTRIES),
        .BP_BTB_ENTRIES(BP_BTB_ENTRIES),
        .BP_RAS_ENTRIES(BP_RAS_ENTRIES)
    ) fethcer (
        .clk(clk), .rst(rst),
        .priv_mode(pmp_priv_mode),
        .pmpcfg0(pmpcfg0_fetch_value),
        .pmp_regions(pmp_regions_fetch_value),
        .satp(satp_fetch_value),
        .sstatus_sum(sstatus_sum_fetch_value),
        .sstatus_mxr(sstatus_mxr_fetch_value),
        .translation_flush(translation_flush_fetch_value),
        .core_if(i_membus_core),
        .mem_if(i_membus)
    );

    core c (
        .clk(clk), .rst(rst),
        .i_membus(i_membus_core),
        .d_membus(d_membus_core),
        .amo_commit_valid(amo_commit_valid),
        .amo_commit_wdata(amo_commit_wdata),
        .led(led),
        .amo_reservation_clear_o(amo_reservation_clear),
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
        .external_meip(v_meip),
        .external_seip(v_seip),
        .aclint(aclint_core_bus)
    );
endmodule
