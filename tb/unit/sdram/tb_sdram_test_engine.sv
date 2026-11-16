`timescale 1ns/1ps
module tb_sdram_test_engine #(parameter bit INJECT_BAD_DATA=0, parameter int unsigned CLK_HZ=50_000_000);
    logic clk=0; always #(500_000_000.0/CLK_HZ) clk=~clk;
    logic rst_n=0;
    logic restart=0, corrupt=INJECT_BAD_DATA;
    logic valid,ready,wr,rv,err,pass,fail;
    logic [63:0] addr,wd,rd;
    logic [63:0] failed_addr,failed_expected,failed_actual;
    logic [7:0] be;
    logic nv,nready,nwr,nrv;
    logic [24:0] na;
    logic [15:0] nwd,nrd;
    logic [1:0] nbe;
    logic [12:0] ma;
    logic [1:0] mb,dqm;
    logic cke,csn,rasn,casn,wen,oe;
    logic [15:0] dout,din;
    sdram_test_engine #(.WORDS(32),.HOLD_CYCLES(1000)) engine(.clk(clk),.rst_n(rst_n),.restart(restart),
        .req_valid(valid),.req_ready(ready),.req_addr(addr),.req_write(wr),
        .req_wdata(wd),.req_be(be),.rsp_valid(rv),
        .rsp_data(rd ^ (corrupt ? 64'h0001000000000000 : 64'd0)),.rsp_error(err),
        .passed(pass),.failed(fail),.failed_addr(failed_addr),
        .failed_expected(failed_expected),.failed_actual(failed_actual));
    sdram_bridge64 bridge(.clk(clk),.rst_n(rst_n),.soft_reset(restart),.req_valid(valid),
        .req_ready(ready),.req_addr(addr),.req_write(wr),.req_wdata(wd),.req_be(be),
        .rsp_valid(rv),.rsp_data(rd),.rsp_error(err),.native_valid(nv),.native_ready(nready),
        .native_addr(na),.native_write(nwr),.native_wdata(nwd),.native_be(nbe),
        .native_rsp_valid(nrv),.native_rsp_data(nrd));
    sdram_native16 #(.CLK_HZ(CLK_HZ)) native_dut(.clk(clk),.rst_n(rst_n),.soft_reset(restart),
        .req_valid(nv),.req_ready(nready),.req_addr(na),.req_write(nwr),
        .req_wdata(nwd),.req_be(nbe),.rsp_valid(nrv),.rsp_data(nrd),.init_done(),
        .dram_addr(ma),.dram_ba(mb),.dram_dqm(dqm),.dram_cke(cke),.dram_cs_n(csn),
        .dram_ras_n(rasn),.dram_cas_n(casn),.dram_we_n(wen),.dq_in(din),.dq_out(dout),.dq_oe(oe));
    sdram_pin_model16 #(.CLK_HZ(CLK_HZ)) model(.clk(clk),.rst_n(rst_n),.a(ma),.ba(mb),.dqm(dqm),
        .cke(cke),.csn(csn),.rasn(rasn),.casn(casn),.wen(wen),.oe(oe),.dout(dout),.din(din));
    int operations=0;
    always @(posedge clk) if(rst_n && valid && ready) operations++;
    initial begin
        #100; rst_n=1;
        if(INJECT_BAD_DATA) begin
            while(!pass && !fail) begin @(negedge clk); #1; end
            if(!fail || pass || operations!=3 || failed_addr!=64'h800000f8 ||
                failed_expected!=64'h0123456789abcdef || failed_actual!=64'h0122456789abcdef)
                $fatal(1,"injected failure not recorded correctly");
            repeat(10) begin @(negedge clk); #1;
                if(!fail || valid || pass) $fatal(1,"failure not sticky");
            end
            restart=1; corrupt=0;
            repeat(3) @(negedge clk);
            #1; restart=0;
        end
        while(!pass && !fail) begin @(negedge clk); #1; end
        if(fail || operations!=256*3+32*8+(INJECT_BAD_DATA ? 3 : 0))
            $fatal(1,"test engine failed/count=%0d",operations);
        $display("SDRAM_TEST_ENGINE_PASS injected=%0d operations=%0d",INJECT_BAD_DATA,operations);
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"watchdog"); end
endmodule
