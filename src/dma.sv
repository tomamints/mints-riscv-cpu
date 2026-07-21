import eei::*;

module dma #(
    parameter int XLEN = 64
)(
    input  logic clk,
    input  logic rst,

    // CPU から MMIOアクセス（DMAは slave）
    Membus.slave  mmio,

    // RAMへアクセスする master ポート（arbiterへ）
    Membus.master ram
);

    // ----------------------------
    // MMIO bit / status bit
    // ----------------------------
    localparam int CTRL_START      = 0;
    localparam int CTRL_CLEAR_DONE = 1;
    localparam int CTRL_IRQ_EN     = 2; // 今回未使用（ポーリング）

    localparam int ST_BUSY = 0;
    localparam int ST_DONE = 1;
    localparam int ST_ERR  = 2;

    // ----------------------------
    // MMIO regs (CPUが書く)
    // ----------------------------
    logic [XLEN-1:0] r_src, r_dst;
    logic [XLEN-1:0] r_len;

    logic st_busy, st_done, st_err;
    logic irq_en;

    // MMIO応答（read/write ともに rvalid を返す）
    logic mmio_rvalid_q;
    logic [MEMBUS_DATA_WIDTH-1:0] mmio_rdata_q;

    assign mmio.ready  = 1'b1;
    assign mmio.rvalid = mmio_rvalid_q;
    assign mmio.rdata  = mmio_rdata_q;

    wire mmio_fire = mmio.valid && mmio.ready;
    wire dma_active = (state != IDLE);

    logic start_pulse;

    // ----------------------------
    // DMA FSM
    // ----------------------------
    typedef enum logic [2:0] {
        IDLE,
        READ_REQ,
        READ_WAIT,
        WRITE_REQ,
        DONE,
        ERR
    } state_t;

    state_t state;

    logic [XLEN-1:0] cur_src, cur_dst, rem;
    logic [MEMBUS_DATA_WIDTH-1:0] rd_buf;

    function automatic logic is_bad_align(input logic [XLEN-1:0] a);
        return (a[2:0] != 3'b000); // 8-byte align
    endfunction

    // ============================================================
    // (A) RAM master 出力は always_comb で一箇所駆動（ここが肝）
    // ============================================================
    always_comb begin
        // default
        ram.valid = 1'b0;
        ram.addr  = '0;
        ram.wen   = 1'b0;
        ram.wdata = '0;
        ram.wmask = '0;

        unique case (state)
            READ_REQ: begin
                ram.valid = 1'b1;
                ram.wen   = 1'b0;
                ram.addr  = cur_src;     // ※cur_src はRAMオフセット運用
            end

            WRITE_REQ: begin
                ram.valid = 1'b1;
                ram.wen   = 1'b1;
                ram.addr  = cur_dst;     // ※cur_dst はRAMオフセット運用
                ram.wdata = rd_buf;
                ram.wmask = {(MEMBUS_DATA_WIDTH/8){1'b1}};
            end

            default: ;
        endcase
    end

    // ============================================================
    // (B) always_ff：MMIOレジスタ更新 + FSM state更新だけ
    //     ※ram.* は絶対に触らない
    // ============================================================
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            r_src <= '0;
            r_dst <= '0;
            r_len <= '0;

            st_busy <= 1'b0;
            st_done <= 1'b0;
            st_err  <= 1'b0;
            irq_en  <= 1'b0;

            mmio_rvalid_q <= 1'b0;
            mmio_rdata_q  <= '0;

            start_pulse <= 1'b0;

            state   <= IDLE;
            cur_src <= '0;
            cur_dst <= '0;
            rem     <= '0;
            rd_buf  <= '0;
        end else begin
            // ---- defaults ----
            mmio_rvalid_q <= 1'b0;
            start_pulse <= 1'b0;

            // ----------------------------
            // MMIO read/write
            // ----------------------------
            if (mmio_fire) begin
                mmio_rvalid_q <= 1'b1;

                if (!mmio.wen) begin
                    // READ
                    unique case (mmio.addr)
                        MMAP_DMA_CTRL:   mmio_rdata_q <= {61'b0, irq_en, 1'b0, 1'b0};
                        MMAP_DMA_STATUS: mmio_rdata_q <= {61'b0, st_err, st_done, st_busy};
                        MMAP_DMA_SRC:    mmio_rdata_q <= r_src;
                        MMAP_DMA_DST:    mmio_rdata_q <= r_dst;
                        MMAP_DMA_LEN:    mmio_rdata_q <= r_len;
                        default:         mmio_rdata_q <= '0;
                    endcase
                end else begin
                    // WRITE
                    mmio_rdata_q <= '0;

                    unique case (mmio.addr)
                        MMAP_DMA_CTRL: begin
                            if (mmio.wdata[CTRL_CLEAR_DONE]) begin
                                st_done <= 1'b0;
                                st_err  <= 1'b0;
                            end
                            irq_en <= mmio.wdata[CTRL_IRQ_EN]; // 今回未使用
                            if (mmio.wdata[CTRL_START] && !dma_active) begin
                                start_pulse <= 1'b1;
                            end
                        end
                        MMAP_DMA_SRC: if (!dma_active) r_src <= mmio.wdata[XLEN-1:0];
                        MMAP_DMA_DST: if (!dma_active) r_dst <= mmio.wdata[XLEN-1:0];
                        MMAP_DMA_LEN: if (!dma_active) r_len <= mmio.wdata[XLEN-1:0];
                        default: ;
                    endcase
                end
            end

            // ----------------------------
            // DMA FSM
            // ----------------------------
            unique case (state)
                IDLE: begin
                    st_busy <= 1'b0;

                    if (start_pulse) begin
                        // 開始時は done/err を落とす（事故防止）
                        st_done <= 1'b0;
                        st_err  <= 1'b0;

                        if (is_bad_align(r_src) || is_bad_align(r_dst) || is_bad_align(r_len)) begin
                            st_err <= 1'b1;
                            state  <= ERR;
                        end else if (r_len == 0) begin
                            st_done <= 1'b1;
                            state   <= DONE;
                        end else begin
                            st_busy <= 1'b1;

                            // CPUが絶対アドレスを書いてくる前提で、RAMオフセットに変換
                            cur_src <= r_src - MMAP_RAM_BEGIN;
                            cur_dst <= r_dst - MMAP_RAM_BEGIN;
                            rem     <= r_len;

                            state <= READ_REQ;
                        end
                    end
                end

                READ_REQ: begin
                    // READ_REQ は「要求を出すstate」
                    // handshake成立で次へ
                    if (ram.ready) begin
                        state <= READ_WAIT;
                    end
                end

                READ_WAIT: begin
                    // read の返りを待つ
                    if (ram.rvalid) begin
                        rd_buf <= ram.rdata;
                        state  <= WRITE_REQ;
                    end
                end

                WRITE_REQ: begin
                    // 方針A：writeは ready で完了扱い
                    if (ram.ready) begin
                        cur_src <= cur_src + 8;
                        cur_dst <= cur_dst + 8;
                        rem     <= rem - 8;

                        if (rem == 8) state <= DONE;
                        else          state <= READ_REQ;
                    end
                end

                DONE: begin
                    st_busy <= 1'b0;
                    st_done <= 1'b1;
                    state   <= IDLE;
                end

                ERR: begin
                    st_busy <= 1'b0;
                    // st_err は保持（CPUが clear_done で消す）
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
