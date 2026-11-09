`timescale 1ns/1ps
// Independent command-level SDRAM model; no references to controller internals.
module sdram_pin_model16 (
    input logic clk, rst_n,
    input logic [12:0] a,
    input logic [1:0] ba, dqm,
    input logic cke, csn, rasn, casn, wen, oe,
    input logic [15:0] dout,
    output logic [15:0] din=0
);
    localparam bit INJECT_BAD_DATA=0, INJECT_BAD_INIT=0;
    logic [15:0] memory [int unsigned];
    bit opened[4];
    logic [12:0] rows[4];
    int act_at[4], pre_at[4], write_at[4];
    int cyc=0, refs=0, total_refs=0, last_ref=-100, mrs_at=-100;
    bit configured=0, precharged=0;
    int read_due=-1, release_due=-1;
    logic [15:0] pending_read;
    bit driving=0;
    function automatic logic [15:0] model_read(input int unsigned address);
        return memory.exists(address)!=0 ? memory[address] : 16'hcafe;
    endfunction
    always @(negedge clk) begin : model
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
            if (cyc==release_due) begin driving=0; din=0; end
            if (oe && driving) $fatal(1,"DQ ownership collision");
            if (!cke) $fatal(1,"unexpected clock disable");
            cmd={csn,rasn,casn,wen};
            // Checker self-test: present an illegal command in the power-up wait.
            if(INJECT_BAD_INIT && cyc==20) cmd=4'b0000;
            if (cmd!=4'b0111 && cyc<5000) $fatal(1,"power-up delay too short");
            if (configured && cyc-last_ref>350) $fatal(1,"refresh deadline missed");
            foreach(opened[i])
                if(opened[i] && cyc-act_at[i]>5000) $fatal(1,"maximum active time exceeded");
            if (cmd!=4'b0111 && cyc-last_ref<3) $fatal(1,"refresh recovery too short");
            case(cmd)
                4'b0010: begin // PRECHARGE
                    for(int i=0;i<4;i++) if (a[10] || ba==2'(i)) begin
                        if(opened[i] && cyc-act_at[i]<3) $fatal(1,"tRAS violation");
                        if(cyc-write_at[i]<2) $fatal(1,"write recovery violation");
                        opened[i]=0; pre_at[i]=cyc;
                    end
                    if(a[10]) precharged=1;
                end
                4'b0001: begin // REFRESH
                    if(!precharged) $fatal(1,"refresh before precharge-all");
                    foreach(opened[i])
                        if(opened[i] || cyc-pre_at[i]<1) $fatal(1,"refresh with active bank");
                    last_ref=cyc; refs++; total_refs++;
                end
                4'b0000: begin // MODE REGISTER
                    if(refs<2 || !precharged || a!=13'h030 || ba!=0)
                        $fatal(1,"bad initialization/mode");
                    configured=1; mrs_at=cyc;
                end
                4'b0011: begin // ACTIVATE
                    if(!configured || cyc-mrs_at<3 || opened[ba] || cyc-pre_at[ba]<1)
                        $fatal(1,"illegal activate");
                    rows[ba]=a; opened[ba]=1; act_at[ba]=cyc;
                end
                4'b0101,4'b0100: begin // READ/WRITE, BL1, explicit precharge
                    if(!opened[ba] || cyc-act_at[ba]<1 || a[12:10]!=0)
                        $fatal(1,"illegal column command");
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
endmodule
