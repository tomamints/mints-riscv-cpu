// uart16550_regs: synthesizable NS16550A-style register block with 16-entry
// TX/RX FIFOs, for 8N1 PHYs or a simulation byte backend.
// Spec: fpga/de0-cv/UART_REGS_DESIGN.md (reviewed by Codex,
// Docs/reviews/UART_REGS_DESIGN_REVIEW_CODEX.md). NOT a full 16550 clone:
//   * 8N1 only (LCR[5:0] stored, not applied; LCR[6] break not supported).
//   * MCR loopback/modem lines not implemented (MCR stored only, MSR = 0).
//   * RX trigger fixed at 1 byte (FCR[7:6] stored only), no RX timeout IRQ.
//   * FIFO physically 16 deep; effective capacity 16 when FCR[0]=1, else 1.
//
// Bus (Membus slave, same contract as src/uart_ns16550.sv):
//   * register = addr[2:0] (byte spaced, addr[7:3] ignored); data in byte lane
//     addr[2:0]; a write is applied only if wmask[addr[2:0]] = 1.
//   * accepted on a rising edge with valid && ready; ready stays Low after an
//     accept until valid has been Low for a cycle (no duplicate accept while
//     the master holds valid). rvalid one cycle after accept, for reads and
//     writes, exactly once. Read data and all read side effects use the state
//     BEFORE the accept edge; side effects happen only on that edge.
//
// Byte interfaces:
//   * TX: tx_valid/tx_data -> tx_ready; transfer on valid && ready. tx_valid is
//     Low while LCR[7] (DLAB) = 1 and in the cycle in which an FCR write that
//     clears the TX FIFO is accepted. tx_busy = PHY frame in progress.
//   * RX: rx_push (1-clock event, no ready) with rx_data/rx_fe/rx_bi. If there
//     is no room (after this cycle's pop / clear, against the new capacity)
//     the byte is dropped and LSR.OE is set. rx_space is advisory for a
//     backend that can wait (DPI); a PHY must not depend on it.
//
// Reset: rst is active-low asynchronous (SoC convention).
module uart16550_regs
    import eei::*;
(
    input  logic        clk,
    input  logic        rst,
    Membus.slave        membus,
    output logic        irq,
    output logic [15:0] divisor,
    output logic        tx_valid,
    output logic [7:0]  tx_data,
    input  logic        tx_ready,
    input  logic        tx_busy,
    input  logic        rx_push,
    input  logic [7:0]  rx_data,
    input  logic        rx_fe,
    input  logic        rx_bi,
    output logic        rx_space,
    output logic        diag_tx_overflow,  // sticky until reset: THR write dropped
    output logic        diag_rx_overrun    // sticky until reset: RX byte dropped
);

    localparam logic [4:0] DEPTH = 5'd16;

    localparam logic [2:0] REG_RBR_THR_DLL = 3'd0;
    localparam logic [2:0] REG_IER_DLM     = 3'd1;
    localparam logic [2:0] REG_IIR_FCR     = 3'd2;
    localparam logic [2:0] REG_LCR         = 3'd3;
    localparam logic [2:0] REG_MCR         = 3'd4;
    localparam logic [2:0] REG_LSR         = 3'd5;
    localparam logic [2:0] REG_MSR         = 3'd6;
    localparam logic [2:0] REG_SCR         = 3'd7;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    logic [7:0] dll;
    logic [7:0] dlm;
    logic [7:0] lcr;
    logic [7:0] scr;
    logic [3:0] ier;
    logic [4:0] mcr;
    logic       fcr0;
    // FCR[7:6] is stored only (RX trigger fixed at 1 byte; FCR is write-only).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0] fcr_trig;
    /* verilator lint_on UNUSEDSIGNAL */
    logic       bus_wait_valid_low;

    logic [7:0] tx_mem [16];
    logic [3:0] tx_rd;
    logic [3:0] tx_wr;
    logic [4:0] tx_count;

    logic [9:0] rx_mem [16];   // {bi, fe, data}
    logic [3:0] rx_rd;
    logic [3:0] rx_wr;
    logic [4:0] rx_count;
    logic [4:0] rx_err_cnt;    // entries in the RX FIFO whose raw fe|bi is set
    logic       head_err_ack;  // LSR has reported the current head's FE/BI
    logic       oe;
    logic       thre_pending;

    // ------------------------------------------------------------------
    // Bus decode (combinational, from the current request and state)
    // ------------------------------------------------------------------
    logic       bus_fire;
    logic [2:0] reg_addr;
    logic [7:0] wbyte;
    logic       lane_ok;
    logic       dlab;
    logic       wr;
    logic       rd;

    assign bus_fire = membus.valid && !bus_wait_valid_low;
    assign membus.ready = !bus_wait_valid_low;
    assign reg_addr = membus.addr[2:0];
    assign wbyte    = membus.wdata[reg_addr * 8 +: 8];
    assign lane_ok  = membus.wmask[reg_addr];
    assign dlab     = lcr[7];
    assign wr       = bus_fire && membus.wen && lane_ok;
    assign rd       = bus_fire && !membus.wen;

    logic wr_thr;
    logic wr_dll;
    logic wr_ier;
    logic wr_dlm;
    logic wr_fcr;
    logic wr_lcr;
    logic wr_mcr;
    logic wr_scr;
    logic rd_rbr;
    logic rd_iir;
    logic rd_lsr;

    assign wr_thr = wr && reg_addr == REG_RBR_THR_DLL && !dlab;
    assign wr_dll = wr && reg_addr == REG_RBR_THR_DLL &&  dlab;
    assign wr_ier = wr && reg_addr == REG_IER_DLM     && !dlab;
    assign wr_dlm = wr && reg_addr == REG_IER_DLM     &&  dlab;
    assign wr_fcr = wr && reg_addr == REG_IIR_FCR;
    assign wr_lcr = wr && reg_addr == REG_LCR;
    assign wr_mcr = wr && reg_addr == REG_MCR;
    assign wr_scr = wr && reg_addr == REG_SCR;
    assign rd_rbr = rd && reg_addr == REG_RBR_THR_DLL && !dlab;
    assign rd_iir = rd && reg_addr == REG_IIR_FCR;
    assign rd_lsr = rd && reg_addr == REG_LSR;

    // ------------------------------------------------------------------
    // FCR effects
    // ------------------------------------------------------------------
    logic       fcr_toggle;
    logic       rx_clear;
    logic       tx_clear;
    logic       fcr0_next;
    logic [4:0] cap;
    logic [4:0] cap_next;

    assign fcr_toggle = wr_fcr && (wbyte[0] != fcr0);
    // Clear bits act only when the written FCR[0] is 1; an enable toggle clears both.
    assign rx_clear   = wr_fcr && (fcr_toggle || (wbyte[0] && wbyte[1]));
    assign tx_clear   = wr_fcr && (fcr_toggle || (wbyte[0] && wbyte[2]));
    assign fcr0_next  = wr_fcr ? wbyte[0] : fcr0;
    assign cap        = fcr0      ? DEPTH : 5'd1;
    assign cap_next   = fcr0_next ? DEPTH : 5'd1;

    // ------------------------------------------------------------------
    // TX FIFO
    // ------------------------------------------------------------------
    logic       tx_pop;
    logic [4:0] tx_count_after_pop;
    logic       tx_push;
    logic       tx_overflow_evt;
    logic [4:0] tx_count_next;

    // DLAB and the TX-clear accept cycle suppress the handoff (also for the sim backend).
    assign tx_valid           = (tx_count != 5'd0) && !dlab && !tx_clear;
    assign tx_data            = tx_mem[tx_rd];
    assign tx_pop             = tx_valid && tx_ready;
    assign tx_count_after_pop = tx_count - {4'd0, tx_pop};
    // THR and FCR writes are mutually exclusive, so the current capacity applies.
    assign tx_push            = wr_thr && (tx_count_after_pop < cap);
    assign tx_overflow_evt    = wr_thr && !(tx_count_after_pop < cap);
    assign tx_count_next      = tx_clear ? 5'd0 : (tx_count_after_pop + {4'd0, tx_push});

    // ------------------------------------------------------------------
    // RX FIFO
    // ------------------------------------------------------------------
    logic       rx_dr;
    logic [9:0] rx_head;
    logic       head_has_err;
    logic       rx_pop;
    logic [4:0] rx_count_after_pop;
    logic [4:0] rx_base;
    logic       rx_accept;
    logic       rx_overrun_evt;
    logic [4:0] rx_count_next;
    logic       push_err;
    logic       pop_err;
    logic       head_change;
    logic [3:0] rx_wr_idx;

    assign rx_dr              = (rx_count != 5'd0);
    assign rx_head            = rx_mem[rx_rd];
    assign head_has_err       = rx_dr && (rx_head[8] || rx_head[9]);
    assign rx_pop             = rd_rbr && rx_dr;
    assign rx_count_after_pop = rx_count - {4'd0, rx_pop};
    // RBR read and FCR write are mutually exclusive bus operations.
    assign rx_base            = rx_clear ? 5'd0 : rx_count_after_pop;
    assign rx_accept          = rx_push && (rx_base < cap_next);
    assign rx_overrun_evt     = rx_push && !rx_accept;
    assign rx_count_next      = rx_base + {4'd0, rx_accept};
    assign push_err           = rx_accept && (rx_fe || rx_bi);
    assign pop_err            = rx_pop && (rx_head[8] || rx_head[9]);
    assign head_change        = rx_pop || rx_clear || (rx_accept && rx_base == 5'd0);
    assign rx_wr_idx          = rx_clear ? 4'd0 : rx_wr;
    assign rx_space           = (rx_count_after_pop < cap);

    // ------------------------------------------------------------------
    // LSR / IIR (current state)
    // ------------------------------------------------------------------
    logic       fe_vis;
    logic       bi_vis;
    logic       head_err_visible;
    logic [4:0] unacked_err;
    logic       fifoe;
    logic       thre;
    logic       temt;
    logic [7:0] lsr;
    logic       int_rls;
    logic       int_rda;
    logic       int_thre;
    logic [3:0] iir_id;
    logic [7:0] iir;
    logic       iir_thre_read;

    assign fe_vis           = rx_dr && rx_head[8] && !head_err_ack;
    assign bi_vis           = rx_dr && rx_head[9] && !head_err_ack;
    assign head_err_visible = fe_vis || bi_vis;
    assign unacked_err      = rx_err_cnt - {4'd0, (head_has_err && head_err_ack)};
    assign fifoe            = fcr0 && (unacked_err != 5'd0);
    assign thre             = (tx_count == 5'd0);
    assign temt             = thre && !tx_busy;
    assign lsr              = {fifoe, temt, thre, bi_vis, fe_vis, 1'b0, oe, rx_dr};

    assign int_rls  = ier[2] && (oe || head_err_visible);
    assign int_rda  = ier[0] && rx_dr;
    assign int_thre = ier[1] && thre_pending;
    assign iir_id   = int_rls ? 4'h6 : int_rda ? 4'h4 : int_thre ? 4'h2 : 4'h1;
    assign iir      = {fcr0, fcr0, 2'b00, iir_id};
    assign irq      = int_rls || int_rda || int_thre;
    assign iir_thre_read = rd_iir && !int_rls && !int_rda && int_thre;

    assign divisor = {dlm, dll};

    // ------------------------------------------------------------------
    // THRE pending (decided by the IER value after this cycle's write)
    // ------------------------------------------------------------------
    logic       etbei_next;
    logic       tx_becomes_empty;
    logic       etbei_rise;
    logic       thre_set;
    logic       thre_clr;
    logic       thre_pending_next;

    assign etbei_next       = wr_ier ? wbyte[1] : ier[1];
    assign tx_becomes_empty = (tx_count != 5'd0) && (tx_count_next == 5'd0);
    assign etbei_rise       = wr_ier && !ier[1] && wbyte[1] && (tx_count_next == 5'd0);
    assign thre_set         = tx_becomes_empty || etbei_rise;
    assign thre_clr         = wr_thr || iir_thre_read;
    assign thre_pending_next = !etbei_next ? 1'b0 : (thre_set || (thre_pending && !thre_clr));

    // ------------------------------------------------------------------
    // Read data (state before the accept edge)
    // ------------------------------------------------------------------
    function automatic logic [7:0] read_reg(input logic [2:0] a);
        unique case (a)
            REG_RBR_THR_DLL: read_reg = dlab ? dll : (rx_dr ? rx_head[7:0] : 8'h00);
            REG_IER_DLM:     read_reg = dlab ? dlm : {4'h0, ier};
            REG_IIR_FCR:     read_reg = iir;
            REG_LCR:         read_reg = lcr;
            REG_MCR:         read_reg = {3'b000, mcr};
            REG_LSR:         read_reg = lsr;
            REG_MSR:         read_reg = 8'h00;
            REG_SCR:         read_reg = scr;
            default:         read_reg = 8'h00;
        endcase
    endfunction

    function automatic logic [MEMBUS_DATA_WIDTH-1:0] read_lane(input logic [2:0] a);
        read_lane = '0;
        read_lane[a * 8 +: 8] = read_reg(a);
    endfunction

    // ------------------------------------------------------------------
    // FIFO storage (no reset; content qualified by counts)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (tx_push) begin
            tx_mem[tx_wr] <= wbyte;
        end
        if (rx_accept) begin
            rx_mem[rx_wr_idx] <= {rx_bi, rx_fe, rx_data};
        end
    end

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            membus.rvalid      <= 1'b0;
            membus.rdata       <= '0;
            bus_wait_valid_low <= 1'b0;
            dll          <= 8'h00;
            dlm          <= 8'h00;
            lcr          <= 8'h03;   // same reset value as src/uart_ns16550.sv
            scr          <= 8'h00;
            ier          <= 4'h0;
            mcr          <= 5'h00;
            fcr0         <= 1'b0;
            fcr_trig     <= 2'b00;
            tx_rd        <= '0;
            tx_wr        <= '0;
            tx_count     <= '0;
            rx_rd        <= '0;
            rx_wr        <= '0;
            rx_count     <= '0;
            rx_err_cnt   <= '0;
            head_err_ack <= 1'b0;
            oe           <= 1'b0;
            thre_pending <= 1'b0;
            diag_tx_overflow <= 1'b0;
            diag_rx_overrun  <= 1'b0;
        end else begin
            // Bus handshake / response
            if (bus_fire) begin
                bus_wait_valid_low <= 1'b1;
                membus.rvalid      <= 1'b1;
                membus.rdata       <= membus.wen ? '0 : read_lane(reg_addr);
            end else begin
                membus.rvalid <= 1'b0;
                membus.rdata  <= '0;
                if (!membus.valid) begin
                    bus_wait_valid_low <= 1'b0;
                end
            end

            // Plain registers
            if (wr_dll) dll <= wbyte;
            if (wr_dlm) dlm <= wbyte;
            if (wr_ier) ier <= wbyte[3:0];
            if (wr_lcr) lcr <= wbyte;
            if (wr_mcr) mcr <= wbyte[4:0];
            if (wr_scr) scr <= wbyte;
            if (wr_fcr) begin
                fcr0 <= wbyte[0];
                if (wbyte[0]) begin
                    fcr_trig <= wbyte[7:6];
                end
            end

            // TX FIFO
            tx_count <= tx_count_next;
            if (tx_clear) begin
                tx_rd <= '0;
                tx_wr <= '0;
            end else begin
                tx_rd <= tx_rd + {3'd0, tx_pop};
                tx_wr <= tx_wr + {3'd0, tx_push};
            end

            // RX FIFO
            rx_count <= rx_count_next;
            if (rx_clear) begin
                rx_rd      <= '0;
                rx_wr      <= {3'd0, rx_accept};
                rx_err_cnt <= {4'd0, push_err};
            end else begin
                rx_rd      <= rx_rd + {3'd0, rx_pop};
                rx_wr      <= rx_wr + {3'd0, rx_accept};
                rx_err_cnt <= rx_err_cnt - {4'd0, pop_err} + {4'd0, push_err};
            end

            // Head ack: a new head never inherits an ack given to the old one.
            if (head_change) begin
                head_err_ack <= 1'b0;
            end else if (rd_lsr) begin
                head_err_ack <= 1'b1;
            end

            // OE: sticky, a new overrun wins over the LSR-read clear.
            if (rx_overrun_evt) begin
                oe <= 1'b1;
            end else if (rd_lsr) begin
                oe <= 1'b0;
            end

            thre_pending <= thre_pending_next;

            if (tx_overflow_evt) diag_tx_overflow <= 1'b1;
            if (rx_overrun_evt)  diag_rx_overrun  <= 1'b1;
        end
    end

`ifdef MINTS_SIM
    // Simulation-only diagnostics. A dropped THR write is a software protocol
    // violation (THRE not respected); it is reported loudly here.
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
        end else begin
            if (tx_overflow_evt)
                $error("uart16550_regs: THR write dropped, TX FIFO full (count=%0d cap=%0d)",
                       tx_count, cap);
            if (rx_err_cnt > rx_count)
                $error("uart16550_regs: rx_err_cnt %0d > rx_count %0d", rx_err_cnt, rx_count);
            if (rx_count > DEPTH || tx_count > DEPTH)
                $error("uart16550_regs: FIFO count out of range tx=%0d rx=%0d", tx_count, rx_count);
        end
    end
`endif

endmodule : uart16550_regs
