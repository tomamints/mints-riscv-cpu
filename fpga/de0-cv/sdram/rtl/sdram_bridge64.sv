`timescale 1ns/1ps
// Standalone 64-bit byte-addressed request -> four native16 transactions.
// This is not a Membus adapter: response errors must be connected to the CPU's
// access-fault path before CPU integration. No AMO or multiple outstanding work.
// RAM is [0x80000000,0x84000000); accesses must be 8-byte aligned.
module sdram_bridge64 (
    input logic clk, rst_n,
    input logic soft_reset,
    input logic req_valid,
    output logic req_ready,
    input logic [63:0] req_addr,
    input logic req_write,
    input logic [63:0] req_wdata,
    input logic [7:0] req_be,
    output logic rsp_valid,
    output logic [63:0] rsp_data,
    output logic rsp_error,
    output logic native_valid,
    input logic native_ready,
    output logic [24:0] native_addr,
    output logic native_write,
    output logic [15:0] native_wdata,
    output logic [1:0] native_be,
    input logic native_rsp_valid,
    input logic [15:0] native_rsp_data
);
    typedef enum logic [1:0] {IDLE,SEND,WAIT_REPLY} state_t;
    state_t state;
    logic [24:0] base_halfword;
    logic saved_write;
    logic [63:0] saved_data;
    logic [47:0] read_acc;
    logic [7:0] saved_be;
    logic [1:0] part;
    assign req_ready=rst_n && !soft_reset && state==IDLE;
    assign native_valid=rst_n && !soft_reset && state==SEND;
    assign native_addr=base_halfword+{23'd0,part};
    assign native_write=saved_write;
    assign native_wdata=saved_data[part*16 +:16];
    assign native_be=saved_be[part*2 +:2];
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; base_halfword<='0; saved_write<=0;
            saved_data<='0; saved_be<='0; read_acc<='0; part<='0;
            rsp_valid<=0; rsp_data<='0; rsp_error<=0;
        end else begin
            rsp_valid<=0;
            rsp_error<=0;
            if(soft_reset) begin
                state<=IDLE;
                read_acc<='0;
                part<='0;
            end else begin
            case(state)
                IDLE: if(req_valid && req_ready) begin
                    if(req_addr<64'h80000000 || req_addr>64'h83fffff8 || req_addr[2:0]!=0) begin
                        rsp_valid<=1; rsp_error<=1; rsp_data<=0;
                    end else begin
                        base_halfword<=25'((req_addr-64'h80000000)>>1);
                        saved_write<=req_write; saved_data<=req_wdata;
                        saved_be<=req_be; read_acc<='0; part<='0;
                        state<=SEND;
                    end
                end
                SEND: if(native_ready) state<=WAIT_REPLY;
                WAIT_REPLY: if(native_rsp_valid) begin
                    if(part==2'd3) begin
                        rsp_data<=saved_write ? 64'd0 : {native_rsp_data,read_acc[47:0]};
                        rsp_valid<=1;
                        state<=IDLE;
                    end else begin
                        read_acc[part*16 +:16]<=native_rsp_data;
                        part<=part+1'b1;
                        state<=SEND;
                    end
                end
                default: state<=IDLE;
            endcase
            end
        end
    end
endmodule
