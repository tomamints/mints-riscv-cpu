// CPU-free SDRAM test client for sdram_bridge64.
// Four full-region write/read patterns followed by PASS. Before the sweeps,
// checks all 256 byte masks at the last word. No software or UART required.
module sdram_test_engine #(
    parameter int unsigned WORDS=8_388_608,
    parameter int unsigned HOLD_CYCLES=50_000_000
) (
    input logic clk, rst_n,
    input logic restart,
    output logic req_valid,
    input logic req_ready,
    output logic [63:0] req_addr,
    output logic req_write,
    output logic [63:0] req_wdata,
    output logic [7:0] req_be,
    input logic rsp_valid,
    input logic [63:0] rsp_data,
    input logic rsp_error,
    output logic passed, failed,
    output logic [63:0] failed_addr, failed_expected, failed_actual
);
    typedef enum logic [3:0] {MASK_INIT,MASK_INIT_WAIT,MASK_WRITE,MASK_WRITE_WAIT,
        MASK_READ,MASK_READ_WAIT,SWEEP_WRITE,SWEEP_WRITE_WAIT,
        SWEEP_READ,SWEEP_READ_WAIT,HOLD,DONE,FAIL} state_t;
    state_t state;
    logic [22:0] word_index;
    logic [1:0] pattern;
    logic [7:0] mask;
    logic [31:0] hold_count;
    logic [63:0] expected_data;
    function automatic logic [63:0] test_pattern(input logic [22:0] index,input logic [1:0] p);
        logic [63:0] address_pattern;
        logic [31:0] expanded_index;
        expanded_index={9'd0,index};
        address_pattern={expanded_index^32'hc0de1234,~expanded_index};
        case(p)
            0: return address_pattern;
            1: return ~address_pattern;
            2: return 64'd0;
            3: return '1;
        endcase
    endfunction
    always_comb begin
        req_valid=state==MASK_INIT || state==MASK_WRITE || state==MASK_READ ||
            state==SWEEP_WRITE || state==SWEEP_READ;
        req_valid=req_valid && rst_n && !restart;
        req_addr=64'h80000000+(64'(word_index)<<3);
        req_write=state==MASK_INIT || state==MASK_WRITE || state==SWEEP_WRITE;
        req_be=state==MASK_WRITE ? mask : 8'hff;
        req_wdata=test_pattern(word_index,pattern);
        if(state==MASK_INIT) req_wdata=64'h0123456789abcdef;
        if(state==MASK_WRITE) req_wdata=64'hfedcba9876543210;
        expected_data=test_pattern(word_index,pattern);
        if(state==MASK_READ_WAIT) begin
            // Explicit byte order: byte zero is EF/10, byte seven is 01/FE.
            for(int b=0;b<8;b++)
                expected_data[b*8+:8]=mask[b] ? (8'h10+8'(b*34)) : (8'hef-8'(b*34));
        end
        passed=state==DONE;
        failed=state==FAIL;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=MASK_INIT; word_index<=23'(WORDS-1); pattern<=0; mask<=0;
            hold_count<=0;
            failed_addr<=0; failed_expected<=0; failed_actual<=0;
        end else if(restart) begin
            state<=MASK_INIT; word_index<=23'(WORDS-1); pattern<=0; mask<=0;
            hold_count<=0;
            failed_addr<=0; failed_expected<=0; failed_actual<=0;
        end else begin
            case(state)
                MASK_INIT: if(req_ready) state<=MASK_INIT_WAIT;
                MASK_INIT_WAIT: if(rsp_valid) state<=rsp_error ? FAIL : MASK_WRITE;
                MASK_WRITE: if(req_ready) state<=MASK_WRITE_WAIT;
                MASK_WRITE_WAIT: if(rsp_valid) state<=rsp_error ? FAIL : MASK_READ;
                MASK_READ: if(req_ready) state<=MASK_READ_WAIT;
                SWEEP_WRITE: if(req_ready) state<=SWEEP_WRITE_WAIT;
                SWEEP_WRITE_WAIT: if(rsp_valid) begin
                    if(rsp_error) state<=FAIL;
                    else if(word_index==23'(WORDS-1)) begin
                        word_index<=0; hold_count<=0; state<=HOLD;
                    end
                    else begin word_index<=word_index+1'b1; state<=SWEEP_WRITE; end
                end
                SWEEP_READ: if(req_ready) state<=SWEEP_READ_WAIT;
                HOLD: begin
                    if(hold_count==HOLD_CYCLES-1) state<=SWEEP_READ;
                    else hold_count<=hold_count+1'b1;
                end
                MASK_READ_WAIT,SWEEP_READ_WAIT: if(rsp_valid) begin
                    if(rsp_error || rsp_data!==expected_data) begin
                        state<=FAIL; failed_addr<=req_addr;
                        failed_expected<=expected_data; failed_actual<=rsp_data;
                    end else if(state==MASK_READ_WAIT) begin
                        if(mask==8'hff) begin word_index<=0; state<=SWEEP_WRITE; end
                        else begin mask<=mask+1'b1; state<=MASK_INIT; end
                    end else if(word_index!=23'(WORDS-1)) begin
                        word_index<=word_index+1'b1; state<=SWEEP_READ;
                    end else if(pattern==2'd3) state<=DONE;
                    else begin pattern<=pattern+1'b1; word_index<=0; state<=SWEEP_WRITE; end
                end
                DONE,FAIL: ;
                default: state<=FAIL;
            endcase
        end
    end
endmodule
