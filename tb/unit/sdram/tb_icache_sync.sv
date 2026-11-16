`timescale 1ns/1ps
module tb_icache_sync #(parameter int STYLE = 1);
    import eei::*;
    logic clk=0; always #5 clk=~clk;
    logic rst=0, cancel=0, invalidate=0, qv=0, qr, rv, rr=0;
    logic [63:0] qa=0, rd, ma, md=0;
    logic mv,mready,mrv=0;
    icache #(.LINE_COUNT(32),.DATA_RAM_STYLE(STYLE)) dut(
        .clk(clk),.rst(rst),.cancel(cancel),.invalidate(invalidate),
        .req_valid(qv),.req_ready(qr),.req_addr(qa),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_data(rd),
        .mem_valid(mv),.mem_ready(mready),.mem_addr(ma),.mem_rvalid(mrv),.mem_rdata(md));
    function automatic logic [63:0] word_at(input logic[63:0] a);
        return (a & ~64'h7) ^ 64'h13579bdf2468ace0;
    endfunction
    bit pending=0;
    int delay_left=0, ticks=0, beats=0;
    logic [63:0] saved;
    assign mready=rst && !pending && !mrv && ticks%7!=0;
    always @(posedge clk) begin
        ticks++;
        mrv<=0;
        if(pending) begin
            if(delay_left==0) begin mrv<=1;md<=word_at(saved);pending=0;end
            else delay_left--;
        end
        if(mv && mready) begin
            if(pending) $fatal(1,"overlapping backing requests");
            saved=ma;pending=1;delay_left=ticks%6;beats++;
        end
    end
    task automatic request(input logic[63:0] a);
        @(negedge clk);qa=a;qv=1;
        do @(posedge clk); while(!qr);
        @(negedge clk);qv=0;
    endtask
    task automatic fetch(input logic[63:0] a);
        request(a);
        do @(negedge clk); while(!rv);
        if(rd!==word_at(a)) $fatal(1,"data mismatch addr=%h got=%h",a,rd);
        // Backpressure must preserve the response and its payload.
        repeat(3) begin
            @(negedge clk);
            if(!rv || rd!==word_at(a)) $fatal(1,"response changed under backpressure");
        end
        rr=1;@(negedge clk);rr=0;
    endtask
    task automatic drain();
        wait(dut.state==3'd0);@(negedge clk);
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=1;
        fetch(64'h80000118);drain();
        // Every word of the completed line, including synchronous hit reads.
        for(int w=0;w<4;w++) fetch(64'h80000100+64'(w*8));
        drain();
        // Cancel an accepted hit before the synchronous read is returned.
        request(64'h80000108);cancel=1;
        @(negedge clk);cancel=0;
        repeat(3) begin @(negedge clk);if(rv)$fatal(1,"cancelled hit responded");end
        fetch(64'h80000108);drain();
        // Invalidate an accepted hit, then require a new backing-memory fill.
        request(64'h80000108);invalidate=1;
        @(negedge clk);invalidate=0;
        repeat(3) begin @(negedge clk);if(rv)$fatal(1,"invalidated hit responded");end
        begin int n; n=beats;fetch(64'h80000108);drain();if(beats!=n+4)$fatal(1,"invalidate did not force refill");end
        // Index conflicts, word offsets and critical-word-first fill order.
        for(int n=0;n<200;n++) begin
            fetch(64'h80000000+64'(((n*13)%257)*8));
            if(n%9==0)begin @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;end
        end
        drain();
        $display("ICACHE_SYNC_PASS style=%0d beats=%0d",STYLE,beats);$finish;
    end
    initial begin #2000000;$fatal(1,"watchdog");end
endmodule
