import eei::*;

module amounit (
    input  logic           clk,
    input  logic           rst,   // active-low reset
    input  logic           reservation_clear,
    core_data_if.slave     slave,
    input  logic           slave_low_priority,
    output logic           master_low_priority,
    Membus.master          master,
    output logic           amo_commit_valid,
    output UIntX           amo_commit_wdata
);

// ======================================================
typedef enum logic [3:0] {
    Init,
    WaitReady,
    WaitValid,
    SCSuccess,
    SCFail,
    AMOLoadReady,
    AMOLoadValid,
    AMOStoreReady,
    AMOStoreValid
} State;

State state;

// ======================================================
// inst slave_saved: core_data_if;
// ======================================================
core_data_if slave_saved();
logic slave_saved_low_priority;

// ======================================================
// lr/sc variables (Veryl: var)
// ======================================================
logic is_addr_reserved;
Addr  reserved_addr;

// ======================================================
// amo variable
// ======================================================
UIntX zaamo_fetched_data;
UIntX zaamo_written_data;

assign amo_commit_valid = (state == AMOStoreValid) && master.rvalid;
assign amo_commit_wdata = zaamo_written_data;


function automatic void reset_master();
    master.valid = 1'b0;
    master.addr  = '0;
    master.wen   = 1'b0;
    master.wdata = '0;
    master.wmask = '0;
    master_low_priority = 1'b0;
endfunction


// ======================================================
// assign_master(addr, wen, wdata, wmask)
// ======================================================
function automatic void assign_master(
    input Addr  addr,
    input logic wen,
    input UIntX wdata,
    input logic [$bits(UIntX)/8-1:0] wmask,
    input logic low_priority
);
    master.valid = 1'b1;
    master.addr  = addr;
    master.wen   = wen;
    master.wdata = wdata;
    master.wmask = wmask;
    master_low_priority = low_priority;
endfunction


// ======================================================
// calc_amo::<W>()  Veryl → SV に忠実変換
// ======================================================
function automatic logic [31:0] calc_amo_32(
    input AMOOp         amoop,
    input logic [31:0] wdata,
    input logic [31:0] rdata
);
    logic lts;
    logic ltu;

    begin
        lts = ($signed(wdata) < $signed(rdata));
        ltu = (wdata < rdata);

        unique case (amoop)
            SWAP: return wdata;
            ADD : return rdata + wdata;
            XOR : return rdata ^ wdata;
            AND : return rdata & wdata;
            OR  : return rdata | wdata;
            MIN : return (lts ? wdata : rdata);
            MAX : return (!lts ? wdata : rdata);
            MINU: return (ltu ? wdata : rdata);
            MAXU: return (!ltu ? wdata : rdata);
            default    : return '0;
        endcase
    end
endfunction

function automatic logic [63:0] calc_amo_64(
    input AMOOp         amoop,
    input logic [63:0] wdata,
    input logic [63:0] rdata
);
    logic lts;
    logic ltu;

    begin
        lts = ($signed(wdata) < $signed(rdata));
        ltu = (wdata < rdata);

        unique case (amoop)
            SWAP: return wdata;
            ADD : return rdata + wdata;
            XOR : return rdata ^ wdata;
            AND : return rdata & wdata;
            OR  : return rdata | wdata;
            MIN : return (lts ? wdata : rdata);
            MAX : return (!lts ? wdata : rdata);
            MINU: return (ltu ? wdata : rdata);
            MAXU: return (!ltu ? wdata : rdata);
            default    : return '0;
        endcase
    end
endfunction

// ======================================================
// gen_amo_wdata(req, rdata)
// ======================================================
function automatic UIntX gen_amo_wdata(
    input logic [XLEN-1:0]              req_addr,
    input logic [MEMBUS_DATA_WIDTH-1:0] req_wdata,
    input AMOOp                         req_amoop,
    input logic [2:0]                   req_funct3,
    input UIntX                         rdata
);
    UIntX result_x;
    begin
        result_x = '0;

        unique case (req_funct3)
            3'b010: begin
                logic  low;
                UInt32 rdata32;
                UInt32 wdata32;
                UInt32 result32;

                low     = (req_addr[2] == 1'b0);
                rdata32 = low ? rdata[31:0] : rdata[63:32];
                wdata32 = low ? req_wdata[31:0] : req_wdata[63:32];

                result32 = calc_amo_32(req_amoop, wdata32, rdata32);

                if (low)
                    return {rdata[63:32], result32};
                else
                    return {result32, rdata[31:0]};
            end

            3'b011: begin
                return calc_amo_64(req_amoop, req_wdata, rdata);
            end

            default: begin
                return '0;
            end
        endcase

        gen_amo_wdata = result_x;
    end
endfunction


// ======================================================
// accept_request_comb()
// ======================================================
function automatic void accept_request_comb();
    if (slave.ready && slave.valid) begin
        if (slave.is_amo) begin
            unique case (slave.amoop)
                LR: begin
                    assign_master(slave.addr, 1'b0, '0, '0, 1'b0);
                end

                SC: begin
                    if (is_addr_reserved && (slave.addr == reserved_addr)) begin
                        assign_master(
                            slave.addr,
                            1'b1,
                            slave.wdata,
                            slave.wmask,
                            1'b0
                        );
                    end
                end

                default: begin
                    if (slave.is_Zaamo()) begin
                        assign_master(slave.addr, 1'b0, '0, '0, 1'b0);
                    end
                end
            endcase
        end else begin
            assign_master(slave.addr, slave.wen, slave.wdata, slave.wmask, slave_low_priority);
        end
    end
endfunction


// ======================================================
// slave outputs (always_comb)
// ======================================================
always_comb begin
    slave.ready  = 1'b0;
    slave.rvalid = 1'b0;
    slave.rdata  = '0;

    unique case (state)

        Init: begin
            slave.ready = 1'b1;
        end

        WaitValid: begin
            slave.ready  = master.rvalid;
            slave.rvalid = master.rvalid;
            slave.rdata  = master.rdata;
        end

        SCSuccess: begin
            slave.ready  = master.rvalid;
            slave.rvalid = master.rvalid;
            slave.rdata  = '0;
        end

        SCFail: begin
            slave.ready  = 1'b1;
            slave.rvalid = 1'b1;
            slave.rdata  = {{($bits(UIntX)-1){1'b0}}, 1'b1};
        end

        AMOStoreValid: begin
            slave.ready  = master.rvalid;
            slave.rvalid = master.rvalid;
            slave.rdata  = zaamo_fetched_data;
        end

        default:;
    endcase
end


// ======================================================
// master outputs (always_comb)
// ======================================================
always_comb begin
    reset_master();

    unique case (state)

        Init: begin
            accept_request_comb();
        end

        WaitReady: begin
            if (slave_saved.is_amo) begin
                unique case (slave_saved.amoop)
                    LR: assign_master(slave_saved.addr, 1'b0, '0, '0, 1'b0);

                    SC: assign_master(
                        slave_saved.addr,
                        1'b1,
                        slave_saved.wdata,
                        slave_saved.wmask,
                        1'b0
                    );

                    default: begin end
                endcase
            end else begin
                assign_master(
                    slave_saved.addr,
                    slave_saved.wen,
                    slave_saved.wdata,
                    slave_saved.wmask,
                    slave_saved_low_priority
                );
            end
        end

        WaitValid: begin
            accept_request_comb();
        end

        SCSuccess,
        SCFail: begin
            accept_request_comb();
        end

        AMOLoadReady: begin
            assign_master(slave_saved.addr, 1'b0, '0, '0, 1'b0);
        end

        AMOLoadValid,
        AMOStoreReady: begin
            UIntX rdata_local;
            UIntX wdata_local;

            rdata_local = (state == AMOLoadValid)
                            ? master.rdata
                            : zaamo_fetched_data;

            wdata_local = gen_amo_wdata(
                slave_saved.addr,
                slave_saved.wdata,
                slave_saved.amoop,
                slave_saved.funct3,
                rdata_local);

            assign_master(
                slave_saved.addr,
                1'b1,
                wdata_local,
                slave_saved.wmask,
                1'b0
            );
        end

        AMOStoreValid: begin
            accept_request_comb();
        end

        default: ;
    endcase
end


// ======================================================
// always_ff (posedge clk or negedge rst)
// on_reset() → 直接展開
// on_clock() → 直接展開
// accept_request_ff() → 直接展開
// ======================================================
always_ff @(posedge clk or negedge rst) begin
    if (!rst) begin
        state              <= Init;
        slave_saved.valid  <= 1'b0;
        slave_saved.addr   <= '0;
        slave_saved.wen    <= 1'b0;
        slave_saved.wdata  <= '0;
        slave_saved.wmask  <= '0;
        slave_saved.is_amo <= 1'b0;
        slave_saved.amoop  <= AMOOp'(0);
        slave_saved.aq     <= 1'b0;
        slave_saved.rl     <= 1'b0;
        slave_saved.funct3 <= 3'b000;
        slave_saved_low_priority <= 1'b0;
        is_addr_reserved   <= 1'b0;
        reserved_addr      <= '0;
        zaamo_fetched_data <= '0;
        zaamo_written_data <= '0;

    end else begin

        // Capture the exact data accepted by the lower memory for a
        // Zaamo store.  This is the architectural new memory value
        // used by the retire/lockstep trace.
        if ((state == AMOLoadValid || state == AMOStoreReady) &&
            master.valid && master.ready && master.wen) begin
            zaamo_written_data <= master.wdata;
        end

        // ======================================================
        // 全状態のメイン FSM
        // ======================================================
        unique case (state)

            // --------------------------------------------------
            Init
            // --------------------------------------------------
            : begin
                slave_saved.valid <= (slave.ready && slave.valid);

                if (slave.ready && slave.valid) begin
                    slave_saved.addr   <= slave.addr;
                    slave_saved.wen    <= slave.wen;
                    slave_saved.wdata  <= slave.wdata;
                    slave_saved.wmask  <= slave.wmask;
                    slave_saved.is_amo <= slave.is_amo;
                    slave_saved.amoop  <= slave.amoop;
                    slave_saved.aq     <= slave.aq;
                    slave_saved.rl     <= slave.rl;
                    slave_saved.funct3 <= slave.funct3;
                    slave_saved_low_priority <= slave_low_priority;

                    if (slave.is_amo) begin
                        unique case (slave.amoop)

                            LR: begin
                                is_addr_reserved <= 1'b1;
                                reserved_addr    <= slave.addr;

                                state <= master.ready ? WaitValid : WaitReady;
                            end

                            SC: begin
                                //reset reserved
                                logic prev;
                                prev = is_addr_reserved;
                                is_addr_reserved <= 1'b0;
                                //check
                                if (prev && (slave.addr == reserved_addr))
                                    state <= master.ready ? SCSuccess : WaitReady;
                                else
                                    state <= SCFail;
                            end

                            default: begin
                                if (slave.is_Zaamo())
                                    state <= master.ready ? AMOLoadValid : AMOLoadReady;
                            end
                        endcase
                    end else begin
                        state <= master.ready ? WaitValid : WaitReady;
                    end

                end else begin
                    state <= Init;
                end
            end


            // --------------------------------------------------
            WaitReady
            // --------------------------------------------------
            : begin
                if (master.ready) begin
                    if (slave_saved.is_amo && slave_saved.amoop == SC)
                        state <= SCSuccess;
                    else
                        state <= WaitValid;
                end
            end


            // --------------------------------------------------
            WaitValid
            // --------------------------------------------------
            : begin
                if (master.rvalid) begin
                    // accept_request_ff() 展開
                    slave_saved.valid <= (slave.ready && slave.valid);

                    if (slave.ready && slave.valid) begin
                        slave_saved.addr   <= slave.addr;
                        slave_saved.wen    <= slave.wen;
                        slave_saved.wdata  <= slave.wdata;
                        slave_saved.wmask  <= slave.wmask;
                        slave_saved.is_amo <= slave.is_amo;
                        slave_saved.amoop  <= slave.amoop;
                        slave_saved.aq     <= slave.aq;
                        slave_saved.rl     <= slave.rl;
                        slave_saved.funct3 <= slave.funct3;
                        slave_saved_low_priority <= slave_low_priority;

                        if (slave.is_amo) begin
                            unique case (slave.amoop)
                                LR: begin
                                    is_addr_reserved <= 1'b1;
                                    reserved_addr    <= slave.addr;
                                    state <= master.ready ? WaitValid : WaitReady;
                                end

                                SC: begin
                                    logic prev;
                                    prev = is_addr_reserved;
                                    is_addr_reserved <= 1'b0;

                                    if (prev && (slave.addr == reserved_addr))
                                        state <= master.ready ? SCSuccess : WaitReady;
                                    else
                                        state <= SCFail;
                                end

                                default: begin
                                    if (slave.is_Zaamo())
                                        state <= master.ready ? AMOLoadValid : AMOLoadReady;
                                end
                            endcase
                        end else begin
                            state <= master.ready ? WaitValid : WaitReady;
                        end

                    end else begin
                        state <= Init;
                    end
                end
            end


            // --------------------------------------------------
            SCSuccess
            // --------------------------------------------------
            : begin
                if (master.rvalid) begin
                    // accept_request_ff() 展開
                    slave_saved.valid <= (slave.ready && slave.valid);

                    if (slave.ready && slave.valid) begin
                        slave_saved.addr   <= slave.addr;
                        slave_saved.wen    <= slave.wen;
                        slave_saved.wdata  <= slave.wdata;
                        slave_saved.wmask  <= slave.wmask;
                        slave_saved.is_amo <= slave.is_amo;
                        slave_saved.amoop  <= slave.amoop;
                        slave_saved.aq     <= slave.aq;
                        slave_saved.rl     <= slave.rl;
                        slave_saved.funct3 <= slave.funct3;
                        slave_saved_low_priority <= slave_low_priority;

                        if (slave.is_amo) begin
                            unique case (slave.amoop)
                                LR: begin
                                    is_addr_reserved <= 1'b1;
                                    reserved_addr    <= slave.addr;
                                    state <= master.ready ? WaitValid : WaitReady;
                                end

                                SC: begin
                                    logic prev;
                                    prev = is_addr_reserved;
                                    is_addr_reserved <= 1'b0;
                                    if (prev && slave.addr == reserved_addr)
                                        state <= master.ready ? SCSuccess : WaitReady;
                                    else
                                        state <= SCFail;
                                end

                                default: begin
                                    if (slave.is_Zaamo())
                                        state <= master.ready ? AMOLoadValid : AMOLoadReady;
                                end
                            endcase
                        end else begin
                            state <= master.ready ? WaitValid : WaitReady;
                        end
                    end else begin
                        state <= Init;
                    end
                end
            end


            // --------------------------------------------------
            SCFail
            // --------------------------------------------------
            : begin
                // accept_request_ff() 毎サイクル
                slave_saved.valid <= (slave.ready && slave.valid);

                if (slave.ready && slave.valid) begin

                    slave_saved.addr   <= slave.addr;
                    slave_saved.wen    <= slave.wen;
                    slave_saved.wdata  <= slave.wdata;
                    slave_saved.wmask  <= slave.wmask;
                    slave_saved.is_amo <= slave.is_amo;
                    slave_saved.amoop  <= slave.amoop;
                    slave_saved.aq     <= slave.aq;
                    slave_saved.rl     <= slave.rl;
                    slave_saved.funct3 <= slave.funct3;
                    slave_saved_low_priority <= slave_low_priority;

                    if (slave.is_amo) begin
                        unique case (slave.amoop)
                            LR: begin
                                is_addr_reserved <= 1'b1;
                                reserved_addr    <= slave.addr;
                                state <= master.ready ? WaitValid : WaitReady;
                            end

                            SC: begin
                                logic prev;
                                prev = is_addr_reserved;
                                is_addr_reserved <= 1'b0;

                                if (prev && slave.addr == reserved_addr)
                                    state <= master.ready ? SCSuccess : WaitReady;
                                else
                                    state <= SCFail;
                            end

                            default: begin
                                if (slave.is_Zaamo())
                                    state <= master.ready ? AMOLoadValid : AMOLoadReady;
                            end
                        endcase
                    end else begin
                        state <= master.ready ? WaitValid : WaitReady;
                    end

                end else begin
                    state <= Init;
                end
            end


            // --------------------------------------------------
            AMOLoadReady
            // --------------------------------------------------
            : begin
                if (master.ready)
                    state <= AMOLoadValid;
            end


            // --------------------------------------------------
            AMOLoadValid
            // --------------------------------------------------
            : begin
                if (master.rvalid) begin
                    zaamo_fetched_data <= master.rdata;
                    state <= slave.ready ? AMOStoreValid : AMOStoreReady;
                end
            end


            // --------------------------------------------------
            AMOStoreReady
            // --------------------------------------------------
            : begin
                if (master.ready)
                    state <= AMOStoreValid;
            end


            // --------------------------------------------------
            AMOStoreValid
            // --------------------------------------------------
            : begin
                if (master.rvalid) begin

                    slave_saved.valid <= (slave.ready && slave.valid);

                    if (slave.ready && slave.valid) begin
                        slave_saved.addr   <= slave.addr;
                        slave_saved.wen    <= slave.wen;
                        slave_saved.wdata  <= slave.wdata;
                        slave_saved.wmask  <= slave.wmask;
                        slave_saved.is_amo <= slave.is_amo;
                        slave_saved.amoop  <= slave.amoop;
                        slave_saved.aq     <= slave.aq;
                        slave_saved.rl     <= slave.rl;
                        slave_saved.funct3 <= slave.funct3;
                        slave_saved_low_priority <= slave_low_priority;

                        if (slave.is_amo) begin
                            unique case (slave.amoop)
                                LR: begin
                                    is_addr_reserved <= 1'b1;
                                    reserved_addr    <= slave.addr;
                                    state <= master.ready ? WaitValid : WaitReady;
                                end

                                SC: begin
                                    logic prev;
                                    prev = is_addr_reserved;
                                    is_addr_reserved <= 1'b0;

                                    if (prev && slave.addr == reserved_addr)
                                        state <= master.ready ? SCSuccess : WaitReady;
                                    else
                                        state <= SCFail;
                                end

                                default: begin
                                    if (slave.is_Zaamo())
                                        state <= master.ready ? AMOLoadValid : AMOLoadReady;
                                end
                            endcase
                        end else begin
                            state <= master.ready ? WaitValid : WaitReady;
                        end

                    end else begin
                        state <= Init;
                    end

                end
            end


            default: begin
                ;
            end

        endcase

        // A trap/interrupt may invalidate an outstanding LR reservation.
        // This keeps SC behavior conservative and aligned with the
        // architectural freedom allowed for LR/SC implementations.
        if (reservation_clear) begin
            is_addr_reserved <= 1'b0;
        end
    end
end

endmodule
