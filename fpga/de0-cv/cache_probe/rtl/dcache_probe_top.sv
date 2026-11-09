// dcache_probe_top: Quartus analysis-only wrapper for resource baselines of
// rtl/cache/dcache.sv. The core_data_if interfaces are flattened into plain
// ports (all VIRTUAL_PIN; never programmed to a board). Debug outputs are left
// unconnected, as in an FPGA top without the lockstep harness.
// The same wrapper compiles the original dcache (HEAD e9f95e7, no
// DATA_RAM_STYLE parameter) and the candidate: the parameter is passed only
// when the macro DCACHE_HAS_DATA_RAM_STYLE is defined.
import eei::*;

module dcache_probe_top #(
    parameter int unsigned LINE_COUNT = 128,
    parameter int unsigned STORE_BUFFER_DEPTH = 4,
    parameter int unsigned DATA_RAM_STYLE = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        invalidate,
    output logic        flush_busy,
    output logic        mem_low_priority,
    // CPU side
    input  logic        cpu_valid,
    output logic        cpu_ready,
    input  logic [63:0] cpu_addr,
    input  logic        cpu_wen,
    input  logic [63:0] cpu_wdata,
    input  logic [7:0]  cpu_wmask,
    output logic        cpu_rvalid,
    output logic [63:0] cpu_rdata,
    input  logic        cpu_fast_load_req,
    input  logic [63:0] cpu_fast_load_addr,
    input  logic [2:0]  cpu_fast_load_funct3,
    output logic        cpu_fast_load_valid,
    output logic [63:0] cpu_fast_load_data,
    input  logic        cpu_fast_store_req,
    input  logic [63:0] cpu_fast_store_addr,
    output logic        cpu_fast_store_valid,
    input  logic        cpu_is_amo,
    input  logic        cpu_aq,
    input  logic        cpu_rl,
    input  logic [4:0]  cpu_amoop,
    input  logic [2:0]  cpu_funct3,
    // memory side
    output logic        mem_valid,
    input  logic        mem_ready,
    output logic [63:0] mem_addr,
    output logic        mem_wen,
    output logic [63:0] mem_wdata,
    output logic [7:0]  mem_wmask,
    input  logic        mem_rvalid,
    input  logic [63:0] mem_rdata,
    output logic        mem_is_amo,
    output logic        mem_aq,
    output logic        mem_rl,
    output logic [4:0]  mem_amoop,
    output logic [2:0]  mem_funct3
);
    core_data_if cpu_if();
    core_data_if mem_if();

    assign cpu_if.valid            = cpu_valid;
    assign cpu_if.addr             = cpu_addr;
    assign cpu_if.wen              = cpu_wen;
    assign cpu_if.wdata            = cpu_wdata;
    assign cpu_if.wmask            = cpu_wmask;
    assign cpu_if.fast_load_req    = cpu_fast_load_req;
    assign cpu_if.fast_load_addr   = cpu_fast_load_addr;
    assign cpu_if.fast_load_funct3 = cpu_fast_load_funct3;
    assign cpu_if.fast_store_req   = cpu_fast_store_req;
    assign cpu_if.fast_store_addr  = cpu_fast_store_addr;
    assign cpu_if.is_amo           = cpu_is_amo;
    assign cpu_if.aq               = cpu_aq;
    assign cpu_if.rl               = cpu_rl;
    assign cpu_if.amoop            = AMOOp'(cpu_amoop);
    assign cpu_if.funct3           = cpu_funct3;
    assign cpu_ready               = cpu_if.ready;
    assign cpu_rvalid              = cpu_if.rvalid;
    assign cpu_rdata               = cpu_if.rdata;
    assign cpu_fast_load_valid     = cpu_if.fast_load_valid;
    assign cpu_fast_load_data      = cpu_if.fast_load_data;
    assign cpu_fast_store_valid    = cpu_if.fast_store_valid;

    assign mem_valid               = mem_if.valid;
    assign mem_addr                = mem_if.addr;
    assign mem_wen                 = mem_if.wen;
    assign mem_wdata               = mem_if.wdata;
    assign mem_wmask               = mem_if.wmask;
    assign mem_is_amo              = mem_if.is_amo;
    assign mem_aq                  = mem_if.aq;
    assign mem_rl                  = mem_if.rl;
    assign mem_amoop               = mem_if.amoop;
    assign mem_funct3              = mem_if.funct3;
    assign mem_if.ready            = mem_ready;
    assign mem_if.rvalid           = mem_rvalid;
    assign mem_if.rdata            = mem_rdata;
    assign mem_if.fast_load_valid  = 1'b0;
    assign mem_if.fast_load_data   = '0;
    assign mem_if.fast_store_valid = 1'b0;

    dcache #(
        .LINE_COUNT(LINE_COUNT),
        .STORE_BUFFER_DEPTH(STORE_BUFFER_DEPTH),
`ifdef DCACHE_HAS_DATA_RAM_STYLE
        .DATA_RAM_STYLE(DATA_RAM_STYLE),
`endif
        .WRITE_BACK(1'b0)
    ) u_dcache (
        .clk(clk), .rst(rst), .invalidate(invalidate), .flush_busy(flush_busy),
        .mem_low_priority(mem_low_priority),
        .debug_state(), .debug_store_buffer_count(), .debug_store_buffer_issue_valid(),
        .debug_store_buffer_issue_fire(), .debug_store_buffer_empty(), .debug_cpu_cacheable(),
        .debug_cache_hit(), .debug_cpu_store_buffer_overlap(),
        .debug_cacheable_load_can_bypass_store_buffer(), .debug_rsp_valid(), .debug_flush_active(),
        .cpu(cpu_if), .mem(mem_if)
    );
endmodule : dcache_probe_top
