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

    PrivMode pmp_priv_mode;
    UIntX pmpcfg0_fetch_value;
    UIntX pmpaddr0_fetch_value;
    UIntX pmpaddr1_fetch_value;
    UIntX pmpaddr2_fetch_value;
    UIntX pmpaddr3_fetch_value;

    logic memarb_last_i;

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
                    // ====== 入力可視化 ======

                    logic [7:0] ch;
                    ch = dbg_membus.wdata[7:0];

/*
                    if (ch == 8'h00) begin
                        $display("[DEBUG-IO] input = NONE");
                    end else begin
                        $display("[DEBUG-IO] input = '%c' (0x%02h)", ch, ch);
                    end
                    */

                    // =========================

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





    // mmio_controller 調停（I/D のどちらの応答か保持）
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            memarb_last_i     <= 1'b0;
        end else if (mmio_membus.ready && mmio_membus.valid) begin
            memarb_last_i     <= !d_membus.valid;
        end
    end
/*
    always_ff @(posedge clk) begin
        $display("[TOP-MMIO] mmio_v=%b mmio_rdy=%b mmio_rvalid=%b mmio_addr=%h last_i=%b last_addr=%h i_v=%b i_rdy=%b d_v=%b d_rdy=%b memarb_ready=%b",
            mmio_membus.valid,
            mmio_membus.ready,
            mmio_membus.rvalid,
            mmio_membus.addr,
            memarb_last_i,
            memarb_last_iaddr,
            i_membus.valid,
            i_membus.ready,
            d_membus.valid,
            d_membus.ready,
            mmio_membus.ready
        );
        if (mmio_membus.valid && mmio_membus.ready) begin
            $display("[TOP-MMIO] ISSUE addr=%h wen=%b source=%s",
                mmio_membus.addr,
                mmio_membus.wen,
                d_membus.valid ? "DATA" : "IF"
            );
        end
        if (mmio_membus.rvalid) begin
            $display("[TOP-MMIO] RESP last_i=%b data=%h",
                memarb_last_i,
                mmio_membus.rdata
            );
        end
    end
*/
    // I/D → MMIO（要求多重化 & 応答戻し）
    always_comb begin
        i_membus.ready  = mmio_membus.ready && !d_membus.valid;
        i_membus.rvalid = mmio_membus.rvalid && memarb_last_i;
        i_membus.rdata  = mmio_membus.rdata;

        d_membus.ready  = mmio_membus.ready;
        d_membus.rvalid = mmio_membus.rvalid && !memarb_last_i;
        d_membus.rdata  = mmio_membus.rdata;

        mmio_membus.valid = i_membus.valid | d_membus.valid;
        if (d_membus.valid) begin
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

/*
    // mmio <> RAM
    always_comb begin
        ram_membus.valid       = mmio_ram_membus.valid;
        mmio_ram_membus.ready  = ram_membus.ready;
        ram_membus.addr        = addr_to_ramaddr(mmio_ram_membus.addr);
        ram_membus.wen         = mmio_ram_membus.wen;
        ram_membus.wdata       = mmio_ram_membus.wdata;
        ram_membus.wmask       = mmio_ram_membus.wmask;
        mmio_ram_membus.rvalid = ram_membus.rvalid;
        mmio_ram_membus.rdata  = ram_membus.rdata;
    end
*/


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
        .dma_membus  (mmio_dma_membus)
    );

    amounit amou (
        .clk    (clk),
        .rst    (rst),
        .slave  (d_membus_core),
        .master (d_membus)
    );

    dma u_dma(
        .clk (clk),
        .rst (rst),
        .mmio(mmio_dma_membus),
        .ram(dma_ram_membus)
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
        .aclint   (aclint_core_bus)
    );

endmodule : core_top
