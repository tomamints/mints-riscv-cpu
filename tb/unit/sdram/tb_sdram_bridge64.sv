`timescale 1ns/1ps
module tb_sdram_bridge64 #(parameter bit INTEGRATED=0);
    logic clk=0; always #10 clk=~clk;
    logic rst_n=0, valid=0, ready, wr=0, rv, err;
    logic [63:0] addr=0, wd=0, rd;
    logic [7:0] be=0;
    logic nv,nready=0,nwr,nrv=0;
    logic [24:0] na;
    logic [15:0] nwd,nrd=0;
    logic [1:0] nbe;
    sdram_bridge64 dut(.clk(clk),.rst_n(rst_n),.req_valid(valid),.req_ready(ready),
        .req_addr(addr),.req_write(wr),.req_wdata(wd),.req_be(be),
        .rsp_valid(rv),.rsp_data(rd),.rsp_error(err),.native_valid(nv),
        .native_ready(nready),.native_addr(na),.native_write(nwr),
        .native_wdata(nwd),.native_be(nbe),.native_rsp_valid(nrv),.native_rsp_data(nrd));

    // Separate halfword memory, variable acceptance and response delay.
    logic [15:0] mem[int unsigned];
    bit busy=0;
    int delay_left=0, cycles=0, native_count=0;
    logic [15:0] reply;
    bit stalled=0;
    logic [43:0] held;
    generate if(!INTEGRATED) begin : g_mock
    always @(posedge clk) begin
        if(!rst_n) begin busy=0; stalled=0; end
        else begin
            if(stalled && (!nv || {na,nwr,nwd,nbe}!==held)) $fatal(1,"unstable native request");
            stalled=nv && !nready;
            held={na,nwr,nwd,nbe};
            if(nv && nready) begin
                logic [15:0] old;
                if(busy) $fatal(1,"multiple native outstanding");
                old=mem.exists(int'(na))!=0 ? mem[int'(na)] : 16'd0;
                reply=old;
                if(nwr) begin
                    if(nbe[0]) old[7:0]=nwd[7:0];
                    if(nbe[1]) old[15:8]=nwd[15:8];
                    mem[int'(na)]=old;
                    reply=0;
                end
                busy=1; delay_left=(cycles%5)+1; native_count++;
            end
        end
    end
    always @(negedge clk) begin
        cycles++;
        if(!rst_n) begin nready=0; nrv=0; end
        else if(nrv) begin nrv=0; busy=0; nready=0; end
        else if(busy) begin
            nready=0;
            if(delay_left==0) begin nrv=1; nrd=reply; end
            else delay_left--;
        end else nready=(cycles%3)!=0;
    end
    end else begin : g_real
        logic [12:0] ma;
        logic [1:0] mb, mdqm;
        logic cke,csn,rasn,casn,wen,oe;
        logic [15:0] dout,din;
        sdram_native16 native_dut(.clk(clk),.rst_n(rst_n),.req_valid(nv),
            .req_ready(nready),.req_addr(na),.req_write(nwr),.req_wdata(nwd),
            .req_be(nbe),.rsp_valid(nrv),.rsp_data(nrd),.init_done(),
            .dram_addr(ma),.dram_ba(mb),.dram_dqm(mdqm),.dram_cke(cke),
            .dram_cs_n(csn),.dram_ras_n(rasn),.dram_cas_n(casn),.dram_we_n(wen),
            .dq_in(din),.dq_out(dout),.dq_oe(oe));
        sdram_pin_model16 model(.clk(clk),.rst_n(rst_n),.a(ma),.ba(mb),
            .dqm(mdqm),.cke(cke),.csn(csn),.rasn(rasn),.casn(casn),.wen(wen),
            .oe(oe),.dout(dout),.din(din));
        always @(posedge clk) if(rst_n && nv && nready) native_count++;
    end endgenerate
    task automatic step; @(negedge clk); #1; endtask
    task automatic access_word(input logic [63:0] a,input bit w,
        input logic [63:0] d,input logic [7:0] mask,input bit expect_err,
        input logic [63:0] expect_data);
        int n, start_count;
        step(); addr=a; wr=w; wd=d; be=mask; valid=1; start_count=native_count;
        n=0;
        do begin @(posedge clk); n++; if(n>100) $fatal(1,"host accept timeout"); end while(!ready);
        step(); valid=0;
        n=0;
        while(!rv) begin step(); n++; if(n>12000) $fatal(1,"host response timeout"); end
        if(err!==expect_err || (!w && !expect_err && rd!==expect_data))
            $fatal(1,"bridge response mismatch addr=%h data=%h expected=%h err=%b",a,rd,expect_data,err);
        if(native_count-start_count!=(expect_err ? 0 : 4)) $fatal(1,"native access count");
        step();
        if(rv) $fatal(1,"duplicate response");
    endtask
    initial begin
        logic [63:0] expected_word, pattern;
        step(); repeat(3) step(); rst_n=1;
        for(int endpoint=0;endpoint<2;endpoint++) begin
            logic [63:0] target;
            target=endpoint==0 ? 64'h80000000 : 64'h83fffff8;
            for(int m=0;m<256;m++) begin
                expected_word=64'h0123456789abcdef;
                pattern=64'hfedcba9876543210;
                access_word(target,1,expected_word,8'hff,0,0);
                access_word(target,1,pattern,8'(m),0,0);
                for(int b=0;b<8;b++) if((m & (1<<b))!=0) expected_word[b*8+:8]=pattern[b*8+:8];
                access_word(target,0,0,0,0,expected_word);
            end
        end
        // Invalid ranges/alignments must never reach the native address port.
        access_word(64'h7ffffff8,1,'1,8'hff,1,0);
        access_word(64'h84000000,1,'1,8'hff,1,0);
        access_word(64'h180000000,0,0,0,1,0);
        access_word(64'hfffffffffffffff8,1,'1,8'hff,1,0);
        for(int b=1;b<8;b++) access_word(64'h80000000+64'(b),0,0,0,1,0);
        access_word(64'h80000000,0,0,0,0,64'hfedcba9876543210);
        access_word(64'h83fffff8,0,0,0,0,64'hfedcba9876543210);
        $display("SDRAM_BRIDGE64_PASS integrated=%0d native_transactions=%0d",INTEGRATED,native_count);
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"watchdog"); end
endmodule
