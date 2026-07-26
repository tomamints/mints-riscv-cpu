/*
import eei::*;

// 1サイクル分のリクエストを保持するレジスタ
typedef struct packed {
    logic                           valid;
    logic [XLEN-1:0]                addr;
    logic                           wen;
    logic [MEMBUS_DATA_WIDTH-1:0]   wdata;
    logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask;
} MembusReg;

module mmio_controller (
    input   logic clk,
    input   logic rst,
    input   Addr  DBG_ADDR,
    Membus.slave  req_core,
    Membus.master ram_membus,
    Membus.master rom_membus,
    Membus.master dbg_membus,
    Membus.master aclint_membus,
    Membus.master dma_membus
);

    typedef enum logic [3:0] {
        UNKNOWN,
        RAM,
        ROM,
        DEBUG,
        ACLINT,
        DMA
    } Device;

    // outstanding リクエスト保持
    MembusReg   req_saved;
    Device      last_device;
    logic       is_requested;  // デバイス側が ready になったかのラッチ

    // ---------- ユーティリティ ----------
    function void reset_membus_master (
        output logic                           valid,
        output logic [XLEN-1:0]                addr,
        output logic                           wen,
        output logic [MEMBUS_DATA_WIDTH-1:0]   wdata,
        output logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask
    );
        valid = 1'b0;
        addr  = '0;
        wen   = 1'b0;
        wdata = '0;
        wmask = '0;
    endfunction

    function void reset_all_device_masters ();
        reset_membus_master(ram_membus.valid, ram_membus.addr, ram_membus.wen, ram_membus.wdata, ram_membus.wmask);
        reset_membus_master(rom_membus.valid, rom_membus.addr, rom_membus.wen, rom_membus.wdata, rom_membus.wmask);
        reset_membus_master(dbg_membus.valid, dbg_membus.addr, dbg_membus.wen, dbg_membus.wdata, dbg_membus.wmask);
        reset_membus_master(aclint_membus.valid, aclint_membus.addr, aclint_membus.wen, aclint_membus.wdata, aclint_membus.wmask);
        reset_membus_master(dma_membus.valid, dma_membus.addr, dma_membus.wen, dma_membus.wdata, dma_membus.wmask);
    endfunction

    function Device get_device (input Addr addr);
        if (DBG_ADDR <= addr && addr <= DBG_ADDR + 64'd7) return DEBUG;
        if ((MMAP_ROM_BEGIN <= addr) && (addr <= MMAP_ROM_END)) return ROM;
        if ((MMAP_ACLINT_BEGIN <= addr) && (addr <= MMAP_ACLINT_END)) return ACLINT;
        if ((MMAP_DMA_BEGIN <= addr) && (addr <= MMAP_DMA_END)) return DMA;
        if (addr >= MMAP_RAM_BEGIN) return RAM;
        return UNKNOWN;
    endfunction

    function void assign_device_master (
        input  logic                           valid,
        input  logic [XLEN-1:0]                addr,
        input  logic                           wen,
        input  logic [MEMBUS_DATA_WIDTH-1:0]   wdata,
        input  logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask
    );
        unique case (get_device(addr))
            RAM: begin
                ram_membus.valid = valid;
                ram_membus.wen   = wen;
                ram_membus.wdata = wdata;
                ram_membus.wmask = wmask;
                ram_membus.addr  = addr - MMAP_RAM_BEGIN;
            end
            ROM: begin
                rom_membus.valid = valid;
                rom_membus.wen   = wen;
                rom_membus.wdata = wdata;
                rom_membus.wmask = wmask;
                rom_membus.addr  = addr - MMAP_ROM_BEGIN;
            end
            DEBUG: begin
                dbg_membus.valid = valid;
                dbg_membus.wen   = wen;
                dbg_membus.wdata = wdata;
                dbg_membus.wmask = wmask;
                dbg_membus.addr  = addr - DBG_ADDR;
            end
            ACLINT: begin
                aclint_membus.valid = valid;
                aclint_membus.wen   = wen;
                aclint_membus.wdata = wdata;
                aclint_membus.wmask = wmask;
                aclint_membus.addr  = addr - MMAP_ACLINT_BEGIN;
            end
            DMA: begin
                dma_membus.valid = valid;
                dma_membus.wen   = wen;
                dma_membus.wdata = wdata;
                dma_membus.wmask = wmask;
                dma_membus.addr  = addr - MMAP_DMA_BEGIN;
            end
            default: ; // UNKNOWN は捨てる
        endcase
    endfunction

    function logic get_device_ready (input Device device);
        unique case (device)
            RAM: return ram_membus.ready;
            ROM: return rom_membus.ready;
            DEBUG: return dbg_membus.ready;
            ACLINT: return aclint_membus.ready;
            DMA: return dma_membus.ready;
            default: return 1'b0;
        endcase
    endfunction

    function logic get_device_rvalid (input Device device);
        unique case (device)
            RAM: return ram_membus.rvalid;
            ROM: return rom_membus.rvalid;
            DEBUG: return dbg_membus.rvalid;
            ACLINT: return aclint_membus.rvalid;
            DMA: return dma_membus.rvalid;
            default: return 1'b0;
        endcase
    endfunction

    // デバイスの rvalid, rdata を req_core に割当（Veryl の assign_device_slave）
    function void assign_device_slave (
        input  Device                        device,
        output logic                         rvalid,
        output logic [MEMBUS_DATA_WIDTH-1:0] rdata
    );
        rvalid = 1'b0;
        rdata  = '0;
        unique case (device)
            RAM: begin
                rvalid = ram_membus.rvalid;
                rdata  = ram_membus.rdata;
            end
            ROM: begin
                rvalid = rom_membus.rvalid;
                rdata  = rom_membus.rdata;
            end
            DEBUG: begin
                rvalid = dbg_membus.rvalid;
                rdata  = dbg_membus.rdata;
            end
            ACLINT: begin
                rvalid = aclint_membus.rvalid;
                rdata  = aclint_membus.rdata;
            end
            DMA: begin
                rvalid = dma_membus.rvalid;
                rdata  = dma_membus.rdata;
            end
            default: ; // UNKNOWN
        endcase
    endfunction

    // コア側


    always_comb begin
        req_core.ready = 1'b0;
        req_core.rvalid = 1'b0;
        req_core.rdata = '0;

        if (req_saved.valid) begin
            if (is_requested) begin
                assign_device_slave(last_device, req_core.rvalid, req_core.rdata);
                req_core.ready = get_device_rvalid(last_device);
            end
        end else begin
            req_core.ready = 1'b1;
        end
    end


    // ---------- combinational: master配線 & コアへの応答 ----------
    always_comb begin
        // 1) まず全デバイス出力をクリア
        reset_all_device_masters();

        // 2) outstanding があればそれをドライブ
        if (req_saved.valid) begin
            if (is_requested) begin
                if (get_device_rvalid(last_device)) begin
                    if (req_core.ready && req_core.valid) begin
                        assign_device_master(
                            req_core.valid,
                            req_core.addr,
                            req_core.wen,
                            req_core.wdata,
                            req_core.wmask
                        );
                    end
                end
            end else begin
                assign_device_master(
                    req_saved.valid,
                    req_saved.addr,
                    req_saved.wen,
                    req_saved.wdata,
                    req_saved.wmask
                );
            end
        end else begin
            if (req_core.ready && req_core.valid) begin
                assign_device_master(
                    req_core.valid,
                    req_core.addr,
                    req_core.wen,
                    req_core.wdata,
                    req_core.wmask
                );
            end
        end
    end

    // 新しく要求を受け入れる→今回は直接入力で
    function void accept_request ();
        req_saved.valid = req_core.ready && req_core.valid;
        if (req_core.ready && req_core.valid) begin
            last_device  = get_device(req_core.addr);
            is_requested = get_device_ready(last_device);
            // reqを保存
            req_saved.addr  = req_core.addr;
            req_saved.wen   = req_core.wen;
            req_saved.wdata = req_core.wdata;
            req_saved.wmask = req_core.wmask;
        end
    endfunction

    // ---------- sequential: ラッチ/クリア ----------
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            last_device  <= UNKNOWN;
            is_requested <= 1'b0;
            reset_membus_master(req_saved.valid, req_saved.addr, req_saved.wen, req_saved.wdata, req_saved.wmask);
        end else begin
            // デバイス応答を受け取ったら次サイクルで outstanding をクリア
            if (req_saved.valid) begin
                if (is_requested) begin
                    if (get_device_rvalid(last_device)) begin
                        req_saved.valid <= req_core.ready && req_core.valid;
                        if (req_core.ready && req_core.valid) begin
                            last_device  <= get_device(req_core.addr); //アドレスによってデバイス名を検知
                            is_requested <= get_device_ready(last_device);
                            // reqを保存
                            req_saved.addr  <= req_core.addr;
                            req_saved.wen   <= req_core.wen;
                            req_saved.wdata <= req_core.wdata;
                            req_saved.wmask <= req_core.wmask;
                        end
                    end
                end else begin
                    is_requested <= get_device_ready(last_device);
                end
            end else begin
                req_saved.valid <= req_core.ready && req_core.valid;
                if (req_core.ready && req_core.valid) begin
                    last_device  <= get_device(req_core.addr);
                    is_requested <= get_device_ready(last_device);
                    // reqを保存
                    req_saved.addr  <= req_core.addr;
                    req_saved.wen   <= req_core.wen;
                    req_saved.wdata <= req_core.wdata;
                    req_saved.wmask <= req_core.wmask;
                end
            end
        end
    end
endmodule

*/


import eei::*;

// 1サイクル分のリクエストを保持するレジスタ
typedef struct packed {
    logic                             valid;
    logic [XLEN-1:0]                  addr;
    logic                             wen;
    logic [MEMBUS_DATA_WIDTH-1:0]     wdata;
    logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask;
} MembusReg;

module mmio_controller (
    input   logic clk,
    input   logic rst,
    input   Addr  DBG_ADDR,

    Membus.slave  req_core,

    Membus.master ram_membus,
    Membus.master rom_membus,
    Membus.master dbg_membus,
    Membus.master aclint_membus,
    Membus.master plic_membus,
    Membus.master dma_membus,
    Membus.master uart_membus
);

    typedef enum logic [3:0] {
        UNKNOWN,
        RAM,
        ROM,
        DEBUG,
        ACLINT,
        PLIC,
        DMA,
        UART
    } Device;

    // outstanding リクエスト保持（1個だけ）
    MembusReg   req_saved;
    Device      last_device;
    logic       req_issued;

    // ---------- ユーティリティ ----------
    function void reset_membus_master (
        output logic                             valid,
        output logic [XLEN-1:0]                  addr,
        output logic                             wen,
        output logic [MEMBUS_DATA_WIDTH-1:0]     wdata,
        output logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask
    );
        valid = 1'b0;
        addr  = '0;
        wen   = 1'b0;
        wdata = '0;
        wmask = '0;
    endfunction

    function void reset_all_device_masters ();
        reset_membus_master(ram_membus.valid,    ram_membus.addr,    ram_membus.wen,    ram_membus.wdata,    ram_membus.wmask);
        reset_membus_master(rom_membus.valid,    rom_membus.addr,    rom_membus.wen,    rom_membus.wdata,    rom_membus.wmask);
        reset_membus_master(dbg_membus.valid,    dbg_membus.addr,    dbg_membus.wen,    dbg_membus.wdata,    dbg_membus.wmask);
        reset_membus_master(aclint_membus.valid, aclint_membus.addr, aclint_membus.wen, aclint_membus.wdata, aclint_membus.wmask);
        reset_membus_master(plic_membus.valid,   plic_membus.addr,   plic_membus.wen,   plic_membus.wdata,   plic_membus.wmask);
        reset_membus_master(dma_membus.valid,    dma_membus.addr,    dma_membus.wen,    dma_membus.wdata,    dma_membus.wmask);
        reset_membus_master(uart_membus.valid,   uart_membus.addr,   uart_membus.wen,   uart_membus.wdata,   uart_membus.wmask);
    endfunction

    function Device get_device (input Addr addr);
        if (DBG_ADDR <= addr && addr <= DBG_ADDR + 64'd7) return DEBUG;
        if ((MMAP_ROM_BEGIN    <= addr) && (addr <= MMAP_ROM_END))   return ROM;
        if ((MMAP_ACLINT_BEGIN <= addr) && (addr <= MMAP_ACLINT_END))return ACLINT;
        if ((MMAP_PLIC_BEGIN   <= addr) && (addr <= MMAP_PLIC_END))  return PLIC;
        if ((MMAP_DMA_BEGIN    <= addr) && (addr <= MMAP_DMA_END))   return DMA;
        if ((MMAP_UART_BEGIN   <= addr) && (addr <= MMAP_UART_END))  return UART;
        if (addr >= MMAP_RAM_BEGIN)                                  return RAM;
        return UNKNOWN;
    endfunction

    // コアの要求(req_saved)を各デバイスmasterへ割当
    function void assign_device_master (
        input  logic                             valid,
        input  logic [XLEN-1:0]                  addr,
        input  logic                             wen,
        input  logic [MEMBUS_DATA_WIDTH-1:0]     wdata,
        input  logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask
    );
        unique case (get_device(addr))
            RAM: begin
                ram_membus.valid = valid;
                ram_membus.wen   = wen;
                ram_membus.wdata = wdata;
                ram_membus.wmask = wmask;
                ram_membus.addr  = addr - MMAP_RAM_BEGIN;
            end
            ROM: begin
                rom_membus.valid = valid;
                rom_membus.wen   = wen;
                rom_membus.wdata = wdata;
                rom_membus.wmask = wmask;
                rom_membus.addr  = addr - MMAP_ROM_BEGIN;
            end
            DEBUG: begin
                dbg_membus.valid = valid;
                dbg_membus.wen   = wen;
                dbg_membus.wdata = wdata;
                dbg_membus.wmask = wmask;
                dbg_membus.addr  = addr - DBG_ADDR;
            end
            ACLINT: begin
                aclint_membus.valid = valid;
                aclint_membus.wen   = wen;
                aclint_membus.wdata = wdata;
                aclint_membus.wmask = wmask;
                aclint_membus.addr  = addr - MMAP_ACLINT_BEGIN;
            end
            PLIC: begin
                plic_membus.valid = valid;
                plic_membus.wen   = wen;
                plic_membus.wdata = wdata;
                plic_membus.wmask = wmask;
                plic_membus.addr  = addr - MMAP_PLIC_BEGIN;
            end
            DMA: begin
                dma_membus.valid = valid;
                dma_membus.wen   = wen;
                dma_membus.wdata = wdata;
                dma_membus.wmask = wmask;
                dma_membus.addr  = addr - MMAP_DMA_BEGIN;
            end
            UART: begin
                uart_membus.valid = valid;
                uart_membus.wen   = wen;
                uart_membus.wdata = wdata;
                uart_membus.wmask = wmask;
                uart_membus.addr  = addr - MMAP_UART_BEGIN;
            end
            default: ; // UNKNOWN は捨てる
        endcase
    endfunction

    function logic get_device_rvalid (input Device device);
        unique case (device)
            RAM:    return ram_membus.rvalid;
            ROM:    return rom_membus.rvalid;
            DEBUG:  return dbg_membus.rvalid;
            ACLINT: return aclint_membus.rvalid;
            PLIC:   return plic_membus.rvalid;
            DMA:    return dma_membus.rvalid;
            UART:   return uart_membus.rvalid;
            default:return 1'b0;
        endcase
    endfunction

    function logic get_device_ready (input Device device);
        unique case (device)
            RAM:    return ram_membus.ready;
            ROM:    return rom_membus.ready;
            DEBUG:  return dbg_membus.ready;
            ACLINT: return aclint_membus.ready;
            PLIC:   return plic_membus.ready;
            DMA:    return dma_membus.ready;
            UART:   return uart_membus.ready;
            default:return 1'b0;
        endcase
    endfunction

    // デバイスの rvalid, rdata を req_core に割当
    function void assign_device_slave (
        input  Device                        device,
        output logic                         rvalid,
        output logic [MEMBUS_DATA_WIDTH-1:0] rdata
    );
        rvalid = 1'b0;
        rdata  = '0;
        unique case (device)
            RAM: begin
                rvalid = ram_membus.rvalid;
                rdata  = ram_membus.rdata;
            end
            ROM: begin
                rvalid = rom_membus.rvalid;
                rdata  = rom_membus.rdata;
            end
            DEBUG: begin
                rvalid = dbg_membus.rvalid;
                rdata  = dbg_membus.rdata;
            end
            ACLINT: begin
                rvalid = aclint_membus.rvalid;
                rdata  = aclint_membus.rdata;
            end
            PLIC: begin
                rvalid = plic_membus.rvalid;
                rdata  = plic_membus.rdata;
            end
            DMA: begin
                rvalid = dma_membus.rvalid;
                rdata  = dma_membus.rdata;
            end
            UART: begin
                rvalid = uart_membus.rvalid;
                rdata  = uart_membus.rdata;
            end
            default: ; // UNKNOWN
        endcase
    endfunction

    // ============================================================
    // コア側: 1 outstanding
    //  - ready : outstandingが空のときだけ 1
    //  - rvalid: outstanding中、デバイスのrvalidをそのまま返す
    // ============================================================
    always_comb begin
        req_core.ready  = !req_saved.valid;
        req_core.rvalid = 1'b0;
        req_core.rdata  = '0;

        if (req_saved.valid) begin
            assign_device_slave(last_device, req_core.rvalid, req_core.rdata);
        end
    end

    // ============================================================
    // デバイス master 側: device が受理するまで request をドライブ
    // ============================================================
    always_comb begin
        reset_all_device_masters();

        if (req_saved.valid && !req_issued) begin
            assign_device_master(
                1'b1,
                req_saved.addr,
                req_saved.wen,
                req_saved.wdata,
                req_saved.wmask
            );
        end
    end

    // ============================================================
    // sequential: 受付 & 完了
    //  - 受付: 空いてるときに req_core.valid を保存
    //  - issue: デバイスの ready で受理されたら valid drive を止める
    //  - 完了: issue 後にデバイスの rvalid が来たら req_saved.valid を落とす
    // ============================================================
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            last_device <= UNKNOWN;
            req_issued  <= 1'b0;
            reset_membus_master(req_saved.valid, req_saved.addr, req_saved.wen, req_saved.wdata, req_saved.wmask);
        end else begin
            // issue / 完了
            if (req_saved.valid) begin
                if (!req_issued && get_device_ready(last_device)) begin
                    req_issued <= 1'b1;
                end

                if (req_issued && get_device_rvalid(last_device)) begin
                    req_saved.valid <= 1'b0;
                    req_issued      <= 1'b0;
                end
            end

            // 新規受付（空いてるときだけ）
            if (!req_saved.valid && req_core.valid) begin
                req_saved.valid <= 1'b1;
                req_issued      <= 1'b0;
                last_device     <= get_device(req_core.addr);

                req_saved.addr  <= req_core.addr;
                req_saved.wen   <= req_core.wen;
                req_saved.wdata <= req_core.wdata;
                req_saved.wmask <= req_core.wmask;
            end
        end
    end

endmodule
