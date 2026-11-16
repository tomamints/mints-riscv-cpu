`timescale 1ns/1ps
module fifo_contract_check #(parameter int PTR_BITS=2, DATA_BITS=72)
    (input logic clk,output logic done=0);
    typedef struct packed {logic [DATA_BITS-9:0] data; logic [6:0] tag; logic flag;} payload_t;
    logic rst=0,flush=0,wvalid=0,rready=0;
    logic [DATA_BITS-1:0] wdata=0;
    payload_t packed_data,old_data,new_data;
    logic old_wr,old_wr2,old_rv,new_wr,new_wr2,new_rv;
    assign packed_data=wdata;
    fifo_baseline #(.DATA_TYPE(payload_t),.WIDTH(PTR_BITS)) old_fifo(
        .clk(clk),.rst(rst),.flush(flush),.wvalid(wvalid),.rready(rready),.wdata(packed_data),
        .wready(old_wr),.wready_two(old_wr2),.rvalid(old_rv),.rdata(old_data));
    fifo #(.DATA_WIDTH($bits(payload_t)),.WIDTH(PTR_BITS)) new_fifo(
        .clk(clk),.rst(rst),.flush(flush),.wvalid(wvalid),.rready(rready),.wdata(packed_data),
        .wready(new_wr),.wready_two(new_wr2),.rvalid(new_rv),.rdata(new_data));
    logic [DATA_BITS-1:0] expected[$];
    localparam int CAPACITY=(1<<PTR_BITS)-1;
    int pushes=0,pops=0,fulls=0,empties=0,together=0,flushes=0;
    logic [63:0] rng;
    function automatic logic [63:0] next_rng(input logic [63:0] v);
        logic [63:0] x=v; x=x^(x<<13);x=x^(x>>7);x=x^(x<<17);return x;
    endfunction
    task automatic cycle(input bit v,r,f,input logic [DATA_BITS-1:0] data);
        @(negedge clk); #1; wvalid=v; rready=r; flush=f; wdata=data;
        @(posedge clk); #1;
    endtask
    always @(posedge clk) begin
        logic [DATA_BITS-1:0] discarded;
        bit want_wr,want_rv,want_wr2;
        if(!rst) begin
            expected.delete();
            if(old_rv || new_rv) $fatal(1,"%m valid during reset");
        end else begin
            want_rv=expected.size()!=0;
            want_wr=expected.size()<CAPACITY || (PTR_BITS==1 && rready);
            want_wr2=PTR_BITS>1 && expected.size()<CAPACITY-1;
            if({old_wr,old_wr2,old_rv} !== {new_wr,new_wr2,new_rv})
                $fatal(1,"%m baseline/vector handshake differs");
            if({new_wr,new_wr2,new_rv} !== {want_wr,want_wr2,want_rv})
                $fatal(1,"%m queue handshake count=%0d",expected.size());
            if(want_rv && (new_data !== expected[0] || old_data !== expected[0]))
                $fatal(1,"%m payload mismatch expected=%h old=%h new=%h",expected[0],old_data,new_data);
            if(expected.size()==CAPACITY) fulls++;
            if(expected.size()==0) empties++;
            if(flush) begin expected.delete();flushes++;end
            else begin
                if(want_rv && rready) begin discarded=expected.pop_front();pops++;end
                if(want_wr && wvalid) begin expected.push_back(wdata);pushes++;end
                if(want_wr && wvalid && want_rv && rready) together++;
            end
        end
    end
    initial begin
        logic [DATA_BITS-1:0] data;
        bit v,r,f;
        rng=64'h2026111000123456 ^ 64'(PTR_BITS*1024+DATA_BITS);
        repeat(3) @(posedge clk);
        @(negedge clk);#1;rst=1;
        for(int i=0;i<CAPACITY+3;i++) cycle(1,0,0,DATA_BITS'(i));
        cycle(1,0,1,'1); // flush wins over a write, including a full queue
        for(int i=0;i<CAPACITY+3;i++) cycle(1,0,0,DATA_BITS'(i));
        repeat(20) cycle(1,1,0,'1);
        repeat(CAPACITY+3) cycle(0,1,0,0);
        for(int b=0;b<DATA_BITS;b++) begin
            data='0;data[b]=1;cycle(1,1,0,data);
            data='1;data[b]=0;cycle(1,1,0,data);
        end
        for(int n=0;n<10000;n++) begin
            rng=next_rng(rng);v=rng[0] || rng[1];r=rng[2];f=rng[15:8]==8'h7d;
            for(int b=0;b<DATA_BITS;b++) begin
                if(b%64==0) rng=next_rng(rng);
                data[b]=rng[b%64];
            end
            cycle(v,r,f,data);
            if(n==5000) begin
                @(negedge clk);#1;rst=0;
                repeat(3) @(posedge clk);
                @(negedge clk);#1;rst=1;
            end
        end
        repeat(CAPACITY+3) cycle(0,1,0,0);
        if(expected.size()!=0 || pushes==0 || pops==0 || fulls==0 || empties==0 || together==0 || flushes==0)
            $fatal(1,"%m missing coverage");
        $display("FIFO_CONTRACT_PASS ptr=%0d data=%0d push=%0d pop=%0d full=%0d both=%0d flush=%0d",
            PTR_BITS,DATA_BITS,pushes,pops,fulls,together,flushes);
        done=1;
    end
endmodule
module tb_fifo_contract;
    logic clk=0;always #5 clk=~clk;
    wire [5:0] done;
    fifo_contract_check #(1,72) c0(clk,done[0]);
    fifo_contract_check #(2,72) c1(clk,done[1]);
    fifo_contract_check #(3,72) c2(clk,done[2]);
    fifo_contract_check #(1,257) c3(clk,done[3]);
    fifo_contract_check #(2,257) c4(clk,done[4]);
    fifo_contract_check #(3,257) c5(clk,done[5]);
    initial begin wait(&done);$display("FIFO_ALL_CONTRACT_PASS");$finish;end
    initial begin #10_000_000;$fatal(1,"watchdog");end
endmodule
