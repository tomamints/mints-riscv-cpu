import eei::*;

// Board SoC logic without the device primitives (PLL, virtual JTAG), so a
// simulation can drive the 20 MHz clock, the cold reset and the JTAG node.
module de0cv_soc_core #(
    parameter BOOTROM_HEX = "bootrom_linux.hex",   // untyped for Quartus $readmemh
    parameter int unsigned MAILBOX_WORDS = 1024
) (
    input  wire        clk,
    input  wire        power_n,
    input  wire        locked,
    // virtual JTAG node
    input  wire        tck, tdi, cdr, sdr, udr,
    input  wire [1:0]  vir,
    output wire        tdo,
    output wire [9:0]  LEDR,
    input  wire        UART_RXD,
    output wire        UART_TXD,
    output wire [12:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire        DRAM_CKE, DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N,
    output wire        DRAM_LDQM, DRAM_UDQM,
    inout  wire [15:0] DRAM_DQ
);
    localparam int unsigned CLK_HZ = 20_000_000;
    localparam logic [63:0] RAM_BYTES = 64'h0400_0000;

    // ---------------- JTAG mailbox + loader ----------------
    logic        lcmd_valid, lcmd_ready, lrsp_valid, lrsp_ready, lrsp_error;
    logic [1:0]  lcmd_op;
    logic [63:0] lcmd_offset, lcmd_data, lrsp_data;
    logic [7:0]  lcmd_mask;
    logic        cpu_run, ram_cleared, loader_fault, mem_fault;
    Membus loader_bus();
    Membus ram_up();

    jtag_block_mailbox #(.BLOCK_WORDS(MAILBOX_WORDS)) mailbox (
        .tck(tck), .tdi(tdi), .tdo(tdo), .ir(vir), .cdr(cdr), .sdr(sdr), .udr(udr),
        .clk(clk), .rst_n(power_n),
        .cmd_valid(lcmd_valid), .cmd_ready(lcmd_ready), .cmd_op(lcmd_op), .cmd_offset(lcmd_offset),
        .cmd_data(lcmd_data), .cmd_mask(lcmd_mask),
        .rsp_valid(lrsp_valid), .rsp_ready(lrsp_ready), .rsp_error(lrsp_error), .rsp_data(lrsp_data),
        .cpu_run(cpu_run), .cleared(ram_cleared), .loader_fault(loader_fault), .memory_fault(mem_fault)
    );
    boot_memory_loader #(.RAM_BYTES(RAM_BYTES)) loader (
        .clk(clk), .rst_n(power_n),
        .cmd_valid(lcmd_valid), .cmd_ready(lcmd_ready), .cmd_op(lcmd_op), .cmd_offset(lcmd_offset),
        .cmd_data(lcmd_data), .cmd_mask(lcmd_mask),
        .rsp_valid(lrsp_valid), .rsp_ready(lrsp_ready), .rsp_error(lrsp_error), .rsp_data(lrsp_data),
        .memory_fault(mem_fault), .cpu_run(cpu_run), .cleared(ram_cleared), .fault(loader_fault),
        .memory_bus(loader_bus)
    );

    // ---------------- CPU ----------------
    wire cpu_rst_n = power_n && cpu_run;
    logic        cpu_ram_valid, cpu_ram_wen;
    Addr         cpu_ram_addr;
    UInt64       cpu_ram_wdata;
    logic [7:0]  cpu_ram_wmask;
    UIntX        core_led;
    logic        uart_tx_overflow, uart_rx_overrun;
    logic        rxd_meta = 1'b1, rxd_sync = 1'b1;
    always_ff @(posedge clk) begin rxd_meta <= UART_RXD; rxd_sync <= rxd_meta; end

    core_top #(
        .RAM_FILEPATH_IS_ENV(1'b0), .RAM_FILEPATH(""),
        .ROM_FILEPATH_IS_ENV(1'b0), .ROM_FILEPATH(BOOTROM_HEX),
        .DCACHE_LINE_COUNT(32), .DCACHE_STORE_BUFFER_DEPTH(4), .DCACHE_WRITE_BACK(1'b0),
        .DCACHE_DATA_RAM_STYLE(1), .ICACHE_LINE_COUNT(32), .ICACHE_DATA_RAM_STYLE(1)
    ) cpu (
        .clk(clk), .rst(cpu_rst_n),
        .uart_rx_i(rxd_sync), .uart_tx_o(UART_TXD),
        .uart_tx_overflow_o(uart_tx_overflow), .uart_rx_overrun_o(uart_rx_overrun),
        .MMAP_DBG_ADDR(64'h4000_0000), .led(core_led),
        .ram_valid_o(cpu_ram_valid), .ram_ready_i(ram_up.ready && cpu_run), .ram_addr_o(cpu_ram_addr),
        .ram_wen_o(cpu_ram_wen), .ram_wdata_o(cpu_ram_wdata), .ram_wmask_o(cpu_ram_wmask),
        .ram_rvalid_i(ram_up.rvalid && cpu_run), .ram_rdata_i(ram_up.rdata)
    );

    // ---------------- RAM port owner mux ----------------
    always_comb begin
        if (cpu_run) begin
            ram_up.valid = cpu_ram_valid;
            ram_up.addr  = cpu_ram_addr;
            ram_up.wen   = cpu_ram_wen;
            ram_up.wdata = cpu_ram_wdata;
            ram_up.wmask = cpu_ram_wmask;
        end else begin
            ram_up.valid = loader_bus.valid;
            ram_up.addr  = loader_bus.addr;
            ram_up.wen   = loader_bus.wen;
            ram_up.wdata = loader_bus.wdata;
            ram_up.wmask = loader_bus.wmask;
        end
        loader_bus.ready  = !cpu_run && ram_up.ready;
        loader_bus.rvalid = !cpu_run && ram_up.rvalid;
        loader_bus.rdata  = ram_up.rdata;
    end

    // ---------------- SDRAM path ----------------
    logic        req_valid, req_ready, req_write, rsp_valid, rsp_error;
    logic [63:0] req_addr, req_wdata, rsp_data;
    logic [7:0]  req_be;
    logic        nv, nready, nwrite, nrvalid, init_done, dq_oe;
    logic [24:0] naddr;
    logic [15:0] nwdata, nrdata, dq_out;
    logic [1:0]  nbe, dqm;
    membus_sdram_adapter #(.RAM_BASE(MMAP_RAM_BEGIN), .RAM_SIZE(RAM_BYTES)) adapter (
        .clk(clk), .rst_n(power_n), .soft_reset(1'b0), .up(ram_up),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr), .req_write(req_write),
        .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(rsp_valid), .rsp_data(rsp_data),
        .rsp_error(rsp_error), .fault(mem_fault), .fault_seen(), .fault_kind(), .fault_offset(),
        .fault_abs(), .fault_wen()
    );
    sdram_bridge64 bridge (
        .clk(clk), .rst_n(power_n), .soft_reset(1'b0),
        .req_valid(req_valid), .req_ready(req_ready), .req_addr(req_addr), .req_write(req_write),
        .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_error(rsp_error),
        .native_valid(nv), .native_ready(nready), .native_addr(naddr), .native_write(nwrite),
        .native_wdata(nwdata), .native_be(nbe), .native_rsp_valid(nrvalid), .native_rsp_data(nrdata)
    );
    sdram_native16 #(.CLK_HZ(CLK_HZ)) sdram (
        .clk(clk), .rst_n(power_n), .soft_reset(1'b0),
        .req_valid(nv), .req_ready(nready), .req_addr(naddr), .req_write(nwrite),
        .req_wdata(nwdata), .req_be(nbe), .rsp_valid(nrvalid), .rsp_data(nrdata), .init_done(init_done),
        .dram_addr(DRAM_ADDR), .dram_ba(DRAM_BA), .dram_dqm(dqm), .dram_cke(DRAM_CKE),
        .dram_cs_n(DRAM_CS_N), .dram_ras_n(DRAM_RAS_N), .dram_cas_n(DRAM_CAS_N),
        .dram_we_n(DRAM_WE_N), .dq_in(DRAM_DQ), .dq_out(dq_out), .dq_oe(dq_oe)
    );
    assign DRAM_DQ = dq_oe ? dq_out : 16'hzzzz;
    assign {DRAM_UDQM, DRAM_LDQM} = dqm;

    // ---------------- LEDs ----------------
    logic [23:0] heartbeat = '0;
    always_ff @(posedge clk) heartbeat <= heartbeat + 24'd1;
    logic uart_ovf_seen, uart_orun_seen;
    always_ff @(posedge clk or negedge power_n)
        if (!power_n) begin uart_ovf_seen <= 1'b0; uart_orun_seen <= 1'b0; end
        else begin
            if (uart_tx_overflow) uart_ovf_seen <= 1'b1;
            if (uart_rx_overrun) uart_orun_seen <= 1'b1;
        end
    assign LEDR = {core_led[0], uart_orun_seen, uart_ovf_seen, loader_fault, mem_fault,
                   init_done, cpu_run, ram_cleared, locked, heartbeat[23]};
endmodule
