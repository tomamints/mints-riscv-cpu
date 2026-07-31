import eei::*;

module aclint_memory (
    input logic clk,
    input logic rst,
    Membus.slave membus,
    aclint_if.master aclint
    );

    logic msip0;
    UInt64 mtime;
    UInt64 mtimecmp0;
    logic mtip_q;


    always_comb begin
        aclint.msip = msip0;
        aclint.mtip = mtime >= mtimecmp0;
        aclint.mtime = mtime;
    end

    always_comb begin
        aclint.setssip = 0;
        aclint.setstip = 0;
        if (membus.valid && membus.wen && membus.addr == MMAP_ACLINT_SETSSIP) begin
            aclint.setssip = membus.wdata[0];
        end
        if (membus.valid && membus.wen && membus.addr == MMAP_ACLINT_SETSTIP) begin
            aclint.setstip = membus.wdata[0];
        end
    end

    assign membus.ready = 1;

    Addr addr;
    logic[MEMBUS_DATA_WIDTH-1 : 0] M;
    logic[MEMBUS_DATA_WIDTH-1 : 0] D;

    always_ff @(posedge clk or negedge rst)begin
        if(!rst)begin
            membus.rvalid <= 0;
            membus.rdata  <= 0;
            msip0         <= 0;
            mtime         <= 0;
            mtimecmp0     <= '1;
            mtip_q        <= 0;
        end else begin
            //count up mtime
            mtime += 1;
            if (($test$plusargs("TRACE_TIMER") || $test$plusargs("TRACE_TIMER_ACLINT")) && aclint.mtip != mtip_q) begin
                $display("[TIMER-MTIP] mtip=%b mtime=%h mtimecmp=%h", aclint.mtip, mtime, mtimecmp0);
            end
            mtip_q <= aclint.mtip;
            membus.rvalid <= membus.valid;
            if (membus.valid) begin
                addr = {membus.addr[XLEN-1 : 3], 3'b0};
                if (membus.wen) begin
                    M = membus.wmask_expand(membus.wmask);
                    D = membus.wdata & M;
                    if ($test$plusargs("TRACE_TIMER") ||
                        ($test$plusargs("TRACE_TIMER_ACLINT") &&
                         (addr == MMAP_ACLINT_MTIMECMP || addr == MMAP_ACLINT_SETSTIP))) begin
                        unique case(addr)
                            MMAP_ACLINT_MSIP,
                            MMAP_ACLINT_MTIME,
                            MMAP_CLINT_MTIME,
                            MMAP_ACLINT_MTIMECMP,
                            MMAP_ACLINT_SETSSIP,
                            MMAP_ACLINT_SETSTIP: begin
                                $display("[TIMER-W] addr=%h data=%h mask=%h mtime=%h mtimecmp=%h msip=%b mtip=%b setssip=%b setstip=%b",
                                    addr,
                                    membus.wdata,
                                    membus.wmask,
                                    mtime,
                                    mtimecmp0,
                                    msip0,
                                    aclint.mtip,
                                    aclint.setssip,
                                    aclint.setstip);
                            end
                            default: ;
                        endcase
                    end
                    case(addr)
                        MMAP_ACLINT_MSIP : msip0 <= D[0] | (msip0 & ~M[0]);
                        MMAP_ACLINT_MTIME,
                        MMAP_CLINT_MTIME : mtime <= D | mtime & ~M;
                        MMAP_ACLINT_MTIMECMP : mtimecmp0 <= D | mtimecmp0 & ~M;
                        default: ;
                    endcase
                end else begin
                    case(addr)
                        MMAP_ACLINT_MSIP : membus.rdata <= {63'b0, msip0};
                        MMAP_ACLINT_MTIME,
                        MMAP_CLINT_MTIME : membus.rdata <= mtime;
                        MMAP_ACLINT_MTIMECMP : membus.rdata <= mtimecmp0;
                        default          : membus.rdata <= '0;
                    endcase
                end
            end
        end
    end

endmodule
