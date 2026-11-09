`timescale 1ns/1ps
// Single-clock-domain SDR SDRAM controller, fixed 50 MHz, BL=1, CL=3.
// Commands/data are registered on clk rising edges. The external memory clock
// must rise half a period later. Physical phase and I/O timing require STA.
// One native halfword request outstanding; every request has one response.
// Reset abandons outstanding work and reinitializes memory (contents lost).
module sdram_native16 (
    input logic clk,
    input logic rst_n,
    input logic req_valid,
    output logic req_ready,
    input logic [24:0] req_addr,
    input logic req_write,
    input logic [15:0] req_wdata,
    input logic [1:0] req_be,
    output logic rsp_valid,
    output logic [15:0] rsp_data,
    output logic init_done,
    output logic [12:0] dram_addr,
    output logic [1:0] dram_ba,
    output logic dram_cke,
    output logic dram_cs_n,
    output logic dram_ras_n,
    output logic dram_cas_n,
    output logic dram_we_n,
    output logic [1:0] dram_dqm,
    input logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic dq_oe
);
    // Command tuple is {CS_N,RAS_N,CAS_N,WE_N}.
    localparam logic [3:0] NOP=4'b0111, PRE=4'b0010,
        REF=4'b0001, MRS=4'b0000, ACT=4'b0011,
        READ=4'b0101, WRITE=4'b0100;
    typedef enum logic [3:0] {POWER_WAIT, INIT_PRE, INIT_REF,
        INIT_MRS, INIT_FINISH, IDLE, ACCESS, REF_WAIT} state_t;
    state_t state;
    logic [3:0] command;
    logic [13:0] power_count;
    logic [3:0] phase;
    logic [3:0] refresh_count;
    logic [8:0] refresh_age;
    logic [11:0] saved_addr;
    logic saved_write;
    logic [15:0] saved_data;
    logic [1:0] saved_be;
    logic [15:0] read_data;

    assign {dram_cs_n,dram_ras_n,dram_cas_n,dram_we_n}=command;
    // Refresh admission reserves 16 clocks before the 350-clock target.
    assign req_ready = rst_n && init_done && state==IDLE && refresh_age<9'd334;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=POWER_WAIT;
            command<=NOP;
            power_count<='0;
            phase<='0;
            refresh_count<='0;
            refresh_age<='0;
            saved_addr<='0;
            saved_write<=1'b0;
            saved_data<='0;
            saved_be<='0;
            read_data<='0;
            rsp_valid<=1'b0;
            rsp_data<='0;
            init_done<=1'b0;
            dram_addr<='0;
            dram_ba<='0;
            dram_cke<=1'b1;
            dram_dqm<=2'b11;
            dq_out<='0;
            dq_oe<=1'b0;
        end else begin
            command<=NOP;
            rsp_valid<=1'b0;
            dq_oe<=1'b0;
            if (init_done && refresh_age!=9'h1ff)
                refresh_age<=refresh_age+1'b1;
            case (state)
                POWER_WAIT: begin
                    // 10,000 clocks = 200 us after reset/clock stability.
                    if (power_count==14'd9999) begin
                        command<=PRE;
                        dram_addr<=13'h400; // A10: all banks
                        phase<=4'd0;
                        state<=INIT_PRE;
                    end else power_count<=power_count+1'b1;
                end
                INIT_PRE: begin
                    if (phase==4'd1) begin
                        command<=REF;
                        refresh_count<=4'd1;
                        phase<='0;
                        state<=INIT_REF;
                    end else phase<=phase+1'b1;
                end
                INIT_REF: begin
                    if (phase==4'd3) begin
                        phase<='0;
                        if (refresh_count==4'd8) begin
                            command<=MRS;
                            dram_addr<=13'h030; // BL1, sequential, CL3
                            dram_ba<=2'b00;
                            state<=INIT_MRS;
                        end else begin
                            command<=REF;
                            refresh_count<=refresh_count+1'b1;
                        end
                    end else phase<=phase+1'b1;
                end
                INIT_MRS: begin
                    if (phase==4'd2) state<=INIT_FINISH;
                    else phase<=phase+1'b1;
                end
                INIT_FINISH: begin
                    init_done<=1'b1;
                    refresh_age<='0;
                    dram_dqm<=2'b00;
                    state<=IDLE;
                end
                IDLE: begin
                    if (refresh_age>=9'd334) begin
                        // Every native access closes its row before returning.
                        command<=REF;
                        refresh_age<='0;
                        phase<='0;
                        state<=REF_WAIT;
                    end else if (req_valid && req_ready) begin
                        saved_addr<=req_addr[11:0];
                        saved_write<=req_write;
                        saved_data<=req_wdata;
                        saved_be<=req_be;
                        command<=ACT;
                        dram_addr<=req_addr[24:12];
                        dram_ba<=req_addr[11:10];
                        phase<=4'd1;
                        state<=ACCESS;
                    end
                end
                ACCESS: begin
                    phase<=phase+1'b1;
                    if (phase==4'd2) begin
                        command<=saved_write ? WRITE : READ;
                        dram_addr<={3'b000,saved_addr[9:0]};
                        dram_ba<=saved_addr[11:10];
                        dram_dqm<=saved_write ? ~saved_be : 2'b00;
                        dq_out<=saved_data;
                        dq_oe<=saved_write;
                    end
                    if (phase==4'd3) dram_dqm<=2'b00;
                    // READ at C2/S2, CL3 data launch S4, capture C5.
                    if (phase==4'd5 && !saved_write) read_data<=dq_in;
                    if (phase==4'd6) begin
                        command<=PRE;
                        dram_addr<=13'h400;
                    end
                    if (phase==4'd8) begin
                        rsp_data<=saved_write ? 16'd0 : read_data;
                        rsp_valid<=1'b1;
                        state<=IDLE;
                    end
                end
                REF_WAIT: begin
                    if (phase==4'd3) state<=IDLE;
                    else phase<=phase+1'b1;
                end
                default: state<=POWER_WAIT;
            endcase
        end
    end
endmodule
