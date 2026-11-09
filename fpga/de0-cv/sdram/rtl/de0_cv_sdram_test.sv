module de0_cv_sdram_test(input wire CLOCK_50,KEY0_N,output wire [9:0] LEDR,
    output wire [12:0] DRAM_ADDR,output wire [1:0] DRAM_BA,
    output wire DRAM_CLK,DRAM_CKE,DRAM_CS_N,DRAM_RAS_N,DRAM_CAS_N,DRAM_WE_N,
    output wire DRAM_LDQM,DRAM_UDQM,inout wire [15:0] DRAM_DQ);
    wire clk,locked;
    sdram_board_pll clocking_block(.clock_50(CLOCK_50),.clk(clk),.dram_clk(DRAM_CLK),.locked(locked));
    reg [7:0] power_pipe=0;
    always @(posedge clk or negedge locked)
        if(!locked) power_pipe<=0; else power_pipe<={power_pipe[6:0],1'b1};
    wire power_n=power_pipe[7];
    reg key_meta=1,key_sync=1;
    always @(posedge clk) begin key_meta<=KEY0_N; key_sync<=key_meta; end
    wire soft_reset=!key_sync;
    wire valid,ready,write,rvalid,error,pass,fail;
    wire [63:0] addr,wdata,rdata,failaddr,failexp,failactual;
    wire [7:0] be;
    wire nv,nready,nwrite,nrvalid,init_done,oe;
    wire [24:0] naddr;
    wire [15:0] nwdata,nrdata,dq_out;
    wire [1:0] nbe,dqm;
    sdram_test_engine test(.clk(clk),.rst_n(power_n),.restart(soft_reset),
        .req_valid(valid),.req_ready(ready),.req_addr(addr),.req_write(write),
        .req_wdata(wdata),.req_be(be),.rsp_valid(rvalid),.rsp_data(rdata),.rsp_error(error),
        .passed(pass),.failed(fail),.failed_addr(failaddr),.failed_expected(failexp),.failed_actual(failactual));
    sdram_bridge64 bridge(.clk(clk),.rst_n(power_n),.soft_reset(soft_reset),
        .req_valid(valid),.req_ready(ready),.req_addr(addr),.req_write(write),
        .req_wdata(wdata),.req_be(be),.rsp_valid(rvalid),.rsp_data(rdata),.rsp_error(error),
        .native_valid(nv),.native_ready(nready),.native_addr(naddr),.native_write(nwrite),
        .native_wdata(nwdata),.native_be(nbe),.native_rsp_valid(nrvalid),.native_rsp_data(nrdata));
    sdram_native16 native_dut(.clk(clk),.rst_n(power_n),.soft_reset(soft_reset),
        .req_valid(nv),.req_ready(nready),.req_addr(naddr),.req_write(nwrite),
        .req_wdata(nwdata),.req_be(nbe),.rsp_valid(nrvalid),.rsp_data(nrdata),.init_done(init_done),
        .dram_addr(DRAM_ADDR),.dram_ba(DRAM_BA),.dram_dqm(dqm),.dram_cke(DRAM_CKE),
        .dram_cs_n(DRAM_CS_N),.dram_ras_n(DRAM_RAS_N),.dram_cas_n(DRAM_CAS_N),
        .dram_we_n(DRAM_WE_N),.dq_in(DRAM_DQ),.dq_out(dq_out),.dq_oe(oe));
    assign DRAM_DQ=oe ? dq_out : 16'hzzzz;
    assign {DRAM_UDQM,DRAM_LDQM}=dqm;
    reg [24:0] heartbeat=0;
    always @(posedge clk) heartbeat<=heartbeat+1'b1;
    assign LEDR={power_n,3'b0,fail,pass,init_done,locked,1'b0,heartbeat[24]};
    sdram_jtag_status status(.status({16'h5d4d,13'b0,init_done,fail,pass}),
        .failed_addr(failaddr),.failed_expected(failexp),.failed_actual(failactual));
endmodule
