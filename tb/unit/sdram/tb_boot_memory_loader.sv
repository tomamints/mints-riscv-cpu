`timescale 1ns/1ps
module tb_boot_memory_loader;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,cv=0,cr,rv,rr=0,re,mf=0,run,cleared,fault;
    logic [1:0] op=0;
    logic [63:0] addr=0,data=0,rd;
    logic [7:0] mask=0;
    Membus bus();
    boot_memory_loader #(.RAM_BYTES(64)) dut(
        .clk(clk),.rst_n(rst_n),.cmd_valid(cv),.cmd_ready(cr),.cmd_op(op),
        .cmd_offset(addr),.cmd_data(data),.cmd_mask(mask),.rsp_valid(rv),.rsp_ready(rr),
        .rsp_error(re),.rsp_data(rd),.memory_fault(mf),.cpu_run(run),.cleared(cleared),.fault(fault),.memory_bus(bus));
    logic[63:0] mem[8];
    bit pending=0;
    int ticks=0,delay_left=0,accepts=0,clears=0;
    logic[63:0] response;
    assign bus.ready=rst_n && !pending && !bus.rvalid && ticks%3!=0;
    always @(posedge clk) begin
        ticks++;bus.rvalid<=0;
        if(pending) begin
            if(delay_left==0)begin bus.rvalid<=1;bus.rdata<=response;pending=0;end
            else delay_left--;
        end
        if(bus.valid && bus.ready)begin
            if(bus.addr>=64 || bus.addr[2:0]!=0)$fatal(1,"invalid bus request");
            accepts++;
            if(bus.wen)begin
                for(int b=0;b<8;b++)if(bus.wmask[b])mem[bus.addr>>3][b*8+:8]=bus.wdata[b*8+:8];
                if(bus.wdata==0 && bus.wmask==255)clears++;
            end
            response=mem[bus.addr>>3];pending=1;delay_left=4;
        end
    end
    task automatic send(input logic[1:0] o,input logic[63:0] a,d,input logic[7:0] m);
        @(negedge clk);op=o;addr=a;data=d;mask=m;cv=1;
        do @(posedge clk);while(!cr);
        @(negedge clk);cv=0;
    endtask
    task automatic reply(input bit error,input logic[63:0] expected);
        do @(negedge clk);while(!rv);
        repeat(3)begin
            if(!rv || re!==error || rd!==expected)$fatal(1,"bad/unstable reply error=%b data=%h",re,rd);
            if(run)$fatal(1,"CPU released before reply consumed");
            @(negedge clk);
        end
        rr=1;@(negedge clk);rr=0;
    endtask
    initial begin
        for(int i=0;i<8;i++)mem[i]='1;
        bus.rvalid=0;bus.rdata=0;
        repeat(3)@(negedge clk);rst_n=1;
        send(3,0,64'h4d494e545352554e,0);reply(1,0);
        send(0,0,1,255);reply(1,0);
        if(accepts!=0)$fatal(1,"request before clear");
        send(2,0,0,0);reply(0,0);
        if(clears!=8 || !cleared)$fatal(1,"incomplete clear");
        for(int i=0;i<8;i++)if(mem[i]!=0)$fatal(1,"not all RAM cleared");
        send(0,56,64'h123456789abcdef0,8'h81);reply(0,0);
        send(1,56,0,0);reply(0,64'h12000000000000f0);
        begin int n;n=accepts;
            send(0,64,1,255);reply(1,0);
            send(1,1,0,0);reply(1,0);
            send(1,64'hfffffffffffffff8,0,0);reply(1,0);
            if(accepts!=n)$fatal(1,"invalid address reached memory");
        end
        send(3,0,0,0);reply(1,0);
        send(3,0,64'h4d494e545352554e,0);reply(0,0);
        if(!run || cr || bus.valid)$fatal(1,"release ownership");
        @(negedge clk);rst_n=0;pending=0;repeat(3)@(negedge clk);rst_n=1;
        send(2,0,0,0);wait(pending);@(negedge clk);mf=1;
        reply(1,0);
        if(!fault || run || cr || bus.valid)$fatal(1,"memory fault did not block boot");
        $display("BOOT_MEMORY_LOADER_PASS");$finish;
    end
    initial begin #100000;$fatal(1,"watchdog");end
endmodule
