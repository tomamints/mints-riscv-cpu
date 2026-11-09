`timescale 1ns/1ps
module tb_sdram_native16 #(
    parameter bit INJECT_BAD_INIT=0,
    parameter bit INJECT_BAD_DATA=0,
    parameter bit INJECT_BAD_REFRESH=0
);
    logic clk=0;
    always #10 clk=~clk;
    logic soft_reset=0;
    logic rst_n=0, req_valid=0, req_ready, req_write=0;
    logic [24:0] req_addr=0;
    logic [15:0] req_wdata=0, rsp_data;
    logic [1:0] req_be=0;
    logic rsp_valid, init_done;
    logic [12:0] a;
    logic [1:0] ba, dqm;
    logic cke, csn, rasn, casn, wen, oe;
    logic [15:0] dout, din=0;
    sdram_native16 dut(.clk(clk),.rst_n(rst_n),.soft_reset(soft_reset),.req_valid(req_valid),
        .req_ready(req_ready),.req_addr(req_addr),.req_write(req_write),
        .req_wdata(req_wdata),.req_be(req_be),.rsp_valid(rsp_valid),
        .rsp_data(rsp_data),.init_done(init_done),.dram_addr(a),.dram_ba(ba),
        .dram_cke(cke),.dram_cs_n(csn),.dram_ras_n(rasn),.dram_cas_n(casn),
        .dram_we_n(wen),.dram_dqm(dqm),.dq_in(din),.dq_out(dout),.dq_oe(oe));

    // Pin-side checker: memory sampling edge is nominally 5 ns after clk.
    // Uses decoded pin commands, never DUT state or phase counters.
    logic [15:0] memory [int unsigned];
    logic [15:0] expected [int unsigned];
    bit opened[4];
    logic [12:0] rows[4];
    int act_at[4], pre_at[4], write_at[4];
    int cyc=0, refs=0, total_refs=0, last_ref=-100, mrs_at=-100;
    bit configured=0, precharged=0;
    int read_due=-1, release_due=-1;
    logic [15:0] pending_read;
    bit driving=0;
    int accepts=0, responses=0, cancelled=0;
    logic [24:0] accepted_addr;
    bit outstanding=0;

    function automatic logic [15:0] model_read(input int unsigned address);
        return memory.exists(address)!=0 ? memory[address] : 16'hcafe;
    endfunction
    function automatic logic [15:0] reference_read(input int unsigned address);
        return expected.exists(address)!=0 ? expected[address] : 16'hcafe;
    endfunction

    // Monitor ownership continuously, including the device tHZ tail.
    always @(oe or driving) if(rst_n && oe && driving) $fatal(1,"DQ ownership collision");
    wire memory_clock;
    assign #5 memory_clock=clk;
    always @(posedge memory_clock) begin : model
        logic [3:0] cmd;
        int unsigned address;
        cyc++;
        if (!rst_n) begin
            refs=0; last_ref=-100; configured=0; precharged=0;
            read_due=-1; release_due=-1; driving=0; din=0;
            foreach(opened[i]) begin
                opened[i]=0; act_at[i]=-100; pre_at[i]=-100; write_at[i]=-100;
            end
        end else begin
            if (cyc==read_due) begin
                din=pending_read ^ (INJECT_BAD_DATA ? 16'h0001 : 16'h0000);
                driving=1;
            end
            if (cyc==release_due) begin #6; driving=0; din=16'hd00d ^ 16'(cyc); end
            if (oe && driving) $fatal(1,"DQ ownership collision");
            if (!cke) $fatal(1,"unexpected clock disable");
            cmd={csn,rasn,casn,wen};
            // Checker self-test: present an illegal command in the power-up wait.
            if(INJECT_BAD_INIT && cyc==20) cmd=4'b0000;
            if(INJECT_BAD_REFRESH && configured && cmd==4'b0001) cmd=4'b0111;
            if (cmd!=4'b0111 && cyc<5000) $fatal(1,"power-up delay too short");
            if (cyc==read_due-1 && dqm!=0) $fatal(1,"read DQM pipeline masked");
            if (configured && cyc-last_ref>350) $fatal(1,"refresh deadline missed");
            foreach(opened[i])
                if(opened[i] && cyc-act_at[i]>5000) $fatal(1,"maximum active time exceeded");
            if (cmd!=4'b0111 && cyc-last_ref<4) $fatal(1,"refresh recovery too short");
            case(cmd)
                4'b0010: begin // PRECHARGE
                    for(int i=0;i<4;i++) if (a[10] || ba==2'(i)) begin
                        if(opened[i] && cyc-act_at[i]<6) $fatal(1,"tRAS violation");
                        if(cyc-write_at[i]<2) $fatal(1,"write recovery violation");
                        opened[i]=0; pre_at[i]=cyc;
                    end
                    if(a[10]) precharged=1;
                end
                4'b0001: begin // REFRESH
                    if(!precharged) $fatal(1,"refresh before precharge-all");
                    foreach(opened[i])
                        if(opened[i] || cyc-pre_at[i]<2) $fatal(1,"refresh with active bank");
                    last_ref=cyc; refs++; total_refs++;
                end
                4'b0000: begin // MODE REGISTER
                    if(refs<2 || !precharged || a!=13'h030 || ba!=0)
                        $fatal(1,"bad initialization/mode");
                    configured=1; mrs_at=cyc;
                end
                4'b0011: begin // ACTIVATE
                    if(!configured || cyc-mrs_at<3 || opened[ba] || cyc-pre_at[ba]<2)
                        $fatal(1,"illegal activate");
                    if(a!==accepted_addr[24:12] || ba!==accepted_addr[11:10]) $fatal(1,"native row/bank mapping");
                    rows[ba]=a; opened[ba]=1; act_at[ba]=cyc;
                end
                4'b0101,4'b0100: begin // READ/WRITE, BL1, explicit precharge
                    if(!opened[ba] || cyc-act_at[ba]<2 || a[12:10]!=0)
                        $fatal(1,"illegal column command");
                    if(a[9:0]!==accepted_addr[9:0]) $fatal(1,"native column mapping");
                    address=(int'(rows[ba])*4+int'(ba))*1024+int'(a[9:0]);
                    if(cmd==4'b0100) begin
                        logic [15:0] old;
                        if(!oe) $fatal(1,"write without DQ ownership");
                        old=model_read(address);
                        if(!dqm[0]) old[7:0]=dout[7:0];
                        if(!dqm[1]) old[15:8]=dout[15:8];
                        memory[address]=old; write_at[ba]=cyc;
                    end else begin
                        if(oe || dqm!=0 || read_due>cyc) $fatal(1,"bad read setup");
                        pending_read=model_read(address);
                        // CL3 launches after memory edge READ+2, valid by READ+3.
                        read_due=cyc+2; release_due=cyc+3;
                    end
                end
                4'b0111: ;
                default: $fatal(1,"unsupported SDRAM command %b",cmd);
            endcase
        end
    end
    always @(posedge clk) begin
        if(!rst_n || soft_reset) begin
            if(outstanding) cancelled++;
            outstanding=0;
        end
        else begin
            if(rsp_valid) begin
                if(!outstanding) $fatal(1,"unsolicited response");
                outstanding=0; responses++;
            end
            if(req_valid && req_ready) begin
                if(outstanding || !init_done) $fatal(1,"invalid request acceptance");
                outstanding=1; accepts++; accepted_addr=req_addr;
            end
        end
    end
    task automatic step;
        @(negedge clk); #1;
    endtask
    task automatic transaction(input bit wr,input int unsigned address,
        input logic [15:0] data,input logic [1:0] be);
        logic [15:0] old;
        int n, before_rsp;
        step(); req_addr=25'(address); req_write=wr; req_wdata=data;
        req_be=be; req_valid=1; before_rsp=responses;
        n=0;
        do begin @(posedge clk); n++; if(n>1000) $fatal(1,"request timeout"); end
        while(!req_ready);
        old=reference_read(address);
        step(); req_valid=0;
        n=0;
        while(!rsp_valid) begin step(); n++; if(n>1000) $fatal(1,"response timeout"); end
        if(wr && rsp_data!==0) $fatal(1,"nonzero write response");
        if(!wr && rsp_data!==old) $fatal(1,"read %h got %h expected %h",address,rsp_data,old);
        if(wr) begin
            if(be[0]) old[7:0]=data[7:0];
            if(be[1]) old[15:8]=data[15:8];
            expected[address]=old;
        end
        step();
        if(responses!=before_rsp+1) $fatal(1,"response count");
    endtask
    initial begin : tests
        int unsigned seed, address;
        step(); rst_n=0;
        repeat(4) step();
        rst_n=1;
        while(!init_done) begin step(); if(cyc>11000) $fatal(1,"init timeout"); end
        if(refs!=8) $fatal(1,"initial refresh count");
        // Hit the latest admission point after the last initialization REF.
        while(cyc-last_ref<332) step();
        transaction(0,32'd0,0,0);
        transaction(0,32'd0,0,0); // overlaps the following refresh reservation
        for(int b=0;b<16;b++) begin
            transaction(1,32'd0,16'(1<<b),2'b11);
            transaction(0,32'd0,0,0);
            transaction(1,32'd0,~16'(1<<b),2'b11);
            transaction(0,32'd0,0,0);
        end
        for(int bitno=0;bitno<25;bitno++) begin
            transaction(1,32'(1)<<bitno,16'(bitno),2'b11);
        end
        for(int bitno=0;bitno<25;bitno++) transaction(0,32'(1)<<bitno,0,0);
        for(int mask=0;mask<4;mask++) begin
            transaction(1,32'h01ffffff,16'habcd,2'b11);
            transaction(1,32'h01ffffff,16'h1234,2'(mask));
            transaction(0,32'h01ffffff,0,0);
        end
        seed=32'h20261109;
        for(int i=0;i<1000;i++) begin
            seed=seed^(seed<<13); seed=seed^(seed>>17); seed=seed^(seed<<5);
            address=seed & 32'h1ffffff;
            transaction(1,address,16'(seed>>8),2'(i));
            transaction(0,address,0,0);
        end
        repeat(1000) step();
        // Abandon a read after ACT, before response; restart full initialization.
        step(); req_valid=1; req_write=0; req_addr=25'd1;
        do @(posedge clk); while(!req_ready);
        step(); req_valid=0;
        step(); rst_n=0;
        repeat(3) step();
        if(rsp_valid || req_ready || init_done || oe) $fatal(1,"reset state");
        rst_n=1;
        begin
            int waited;
            waited=0;
            while(!init_done) begin
                if(req_ready || rsp_valid) $fatal(1,"stale activity during reinit");
                step(); waited++;
                if(waited>11000) $fatal(1,"reinitialization timeout");
            end
            if(waited<10000 || refs!=8) $fatal(1,"incomplete reinitialization");
        end
        transaction(1,32'd0,16'h5a5a,2'b11);
        transaction(0,32'd0,0,0);
        // Warm abort must not reset the SDRAM device or stop refresh.
        step(); req_valid=1; req_write=0; req_addr=25'd0;
        do @(posedge clk); while(!req_ready);
        step(); req_valid=0;
        step(); soft_reset=1;
        repeat(6000) step(); // >100us, device bank state remains in the checker
        if(req_ready || rsp_valid || oe || !init_done) $fatal(1,"warm reset state");
        soft_reset=0;
        transaction(0,32'd0,0,0);
        if(total_refs<50 || accepts!=responses+cancelled || cancelled!=2)
            $fatal(1,"coverage/accounting");
        $display("SDRAM_NATIVE16_PASS requests=%0d responses=%0d cancelled=%0d refreshes=%0d",
            accepts,responses,cancelled,total_refs);
        $finish;
    end
    initial begin #10_000_000; $fatal(1,"watchdog"); end
endmodule
