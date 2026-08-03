import eei::*;
import util::*;

module core_top #(
    parameter bit    RAM_FILEPATH_IS_ENV = 1,
    parameter string RAM_FILEPATH        = "RAM_FILE_PATH",
    parameter bit    ROM_FILEPATH_IS_ENV = 1,
    parameter string ROM_FILEPATH        = "ROM_FILE_PATH"
) (
`ifdef TEST_MODE
    output logic test_success,
`endif
    input  logic clk,
    input  logic rst,
    input  Addr  MMAP_DBG_ADDR,
    output UIntX led
);

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
    UIntX pmpaddr0_fetch_value;
    UIntX pmpaddr1_fetch_value;
    UIntX pmpaddr2_fetch_value;
    UIntX pmpaddr3_fetch_value;
    UIntX pmpaddr4_fetch_value;
    UIntX pmpaddr5_fetch_value;
    UIntX pmpaddr6_fetch_value;
    UIntX pmpaddr7_fetch_value;
    UIntX satp_fetch_value;
    logic translation_flush_fetch_value;
    logic sstatus_sum_fetch_value;
    logic sstatus_mxr_fetch_value;
    logic uart_irq;
    logic plic_meip;
    logic plic_seip;
    logic [PLIC_NUM_SOURCES:0] plic_source_irq;

    logic memarb_last_i;
    logic d_membus_low_priority;
    logic dcache_mem_low_priority;
    logic memarb_select_d;
    logic memarb_issue_is_i;
    UInt64 perf_memarb_i_grant_count;
    UInt64 perf_memarb_d_grant_count;
    UInt64 perf_memarb_d_low_grant_count;
    UInt64 perf_memarb_d_low_defer_count;

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
        memarb_select_d = d_membus.valid && !(d_membus_low_priority && i_membus.valid);
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

    // arbiter後のMembus → RAM(=membus_if) 変換
    always_comb begin
        ram_membus.valid = arb_ram_membus.valid;
        arb_ram_membus.ready = ram_membus.ready;

        ram_membus.addr  = addr_to_ramaddr(arb_ram_membus.addr);
        ram_membus.wen   = arb_ram_membus.wen;
        ram_membus.wdata = arb_ram_membus.wdata;
        ram_membus.wmask = arb_ram_membus.wmask;

        arb_ram_membus.rvalid = ram_membus.rvalid;
        arb_ram_membus.rdata  = ram_membus.rdata;
    end



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

    dcache dcache0 (
        .clk        (clk),
        .rst        (rst),
        .invalidate (1'b0),
        .mem_low_priority(dcache_mem_low_priority),
        .cpu        (d_membus_core),
        .mem        (dcache_membus_core)
    );

    amounit amou (
        .clk    (clk),
        .rst    (rst),
        .slave_low_priority(dcache_mem_low_priority),
        .master_low_priority(d_membus_low_priority),
        .slave  (dcache_membus_core),
        .master (d_membus)
    );

    dma u_dma(
        .clk (clk),
        .rst (rst),
        .mmio(mmio_dma_membus),
        .ram(dma_ram_membus)
    );

    uart_ns16550 uart0 (
        .clk    (clk),
        .rst    (rst),
        .membus (uart_membus),
        .irq    (uart_irq)
    );

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



    inst_fetcher fethcer (
        .clk       (clk),
        .rst       (rst),
        .priv_mode (pmp_priv_mode),
        .pmpcfg0   (pmpcfg0_fetch_value),
        .pmpaddr0  (pmpaddr0_fetch_value),
        .pmpaddr1  (pmpaddr1_fetch_value),
        .pmpaddr2  (pmpaddr2_fetch_value),
        .pmpaddr3  (pmpaddr3_fetch_value),
        .pmpaddr4  (pmpaddr4_fetch_value),
        .pmpaddr5  (pmpaddr5_fetch_value),
        .pmpaddr6  (pmpaddr6_fetch_value),
        .pmpaddr7  (pmpaddr7_fetch_value),
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
        .led      (led),
        .pmp_priv_mode(pmp_priv_mode),
        .pmpcfg0_fetch_value(pmpcfg0_fetch_value),
        .pmpaddr0_fetch_value(pmpaddr0_fetch_value),
        .pmpaddr1_fetch_value(pmpaddr1_fetch_value),
        .pmpaddr2_fetch_value(pmpaddr2_fetch_value),
        .pmpaddr3_fetch_value(pmpaddr3_fetch_value),
        .pmpaddr4_fetch_value(pmpaddr4_fetch_value),
        .pmpaddr5_fetch_value(pmpaddr5_fetch_value),
        .pmpaddr6_fetch_value(pmpaddr6_fetch_value),
        .pmpaddr7_fetch_value(pmpaddr7_fetch_value),
        .satp_fetch_value(satp_fetch_value),
        .translation_flush_fetch_value(translation_flush_fetch_value),
        .sstatus_sum_fetch_value(sstatus_sum_fetch_value),
        .sstatus_mxr_fetch_value(sstatus_mxr_fetch_value),
        .external_meip(plic_meip),
        .external_seip(plic_seip),
        .aclint   (aclint_core_bus)
    );

    final begin
        if ($test$plusargs("PERF_SUMMARY")) begin
            $display("[PERF-MEMARB] i_grant=%0d d_grant=%0d d_low_grant=%0d d_low_defer=%0d",
                perf_memarb_i_grant_count,
                perf_memarb_d_grant_count,
                perf_memarb_d_low_grant_count,
                perf_memarb_d_low_defer_count);
        end
    end

endmodule : core_top
