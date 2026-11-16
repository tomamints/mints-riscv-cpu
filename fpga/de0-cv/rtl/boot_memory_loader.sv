// Same-clock boot command engine, upstream of membus_sdram_adapter.
// Transport (JTAG/UART) must supply commands in clk's domain. No CDC here.
// op: 0 write word, 1 read word, 2 clear ALL RAM, 3 release CPU.
// Addresses are byte offsets; reads/writes must be eight-byte aligned.
// Clear writes every byte, including zero regions omitted from sparse images.
// The host must read back and compare all loaded image regions before RELEASE;
// hardware enforces completed clear/no bus fault, but does not authenticate images.
// RELEASE requires data = 64'h4d494e545352554e ("MINTSRUN"). CPU remains held
// until the host consumes the successful release response. After release this
// engine relinquishes the RAM port permanently until cold reset. Board logic
// must multiplex this master with the CPU on cpu_run, without resetting SDRAM.
module boot_memory_loader #(
    parameter int unsigned RAM_BYTES = 64*1024*1024
) (
    input logic clk, rst_n,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [1:0] cmd_op,
    input logic [63:0] cmd_offset, cmd_data,
    input logic [7:0] cmd_mask,
    output logic rsp_valid,
    input logic rsp_ready,
    output logic rsp_error,
    output logic [63:0] rsp_data,
    input logic memory_fault,
    output logic cpu_run, cleared, fault,
    Membus.master memory_bus
);
    typedef enum logic [1:0] {IDLE, ISSUE, WAIT_REPLY, REPLY} state_t;
    state_t state;
    logic clearing, release_pending;
    logic [63:0] offset_q, data_q;
    logic [7:0] mask_q;
    logic write_q;
    assign cmd_ready = rst_n && !cpu_run && !fault && !memory_fault && state==IDLE;
    assign rsp_valid = rst_n && state==REPLY;
    assign memory_bus.valid = rst_n && !fault && !memory_fault && state==ISSUE;
    assign memory_bus.addr = offset_q;
    assign memory_bus.wdata = data_q;
    assign memory_bus.wmask = mask_q;
    assign memory_bus.wen = write_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;cpu_run<=0;cleared<=0;fault<=0;
            clearing<=0;release_pending<=0;offset_q<=0;data_q<=0;mask_q<=0;write_q<=0;
            rsp_error<=0;rsp_data<=0;
        end else if(memory_fault && !cpu_run) begin
            fault<=1;release_pending<=0;
            // One error response for a pending command. No further memory work.
            if(!fault && state!=IDLE && state!=REPLY) begin
                rsp_error<=1;rsp_data<=0;state<=REPLY;
            end
            else if(state==REPLY && rsp_ready) state<=IDLE;
        end else begin
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    rsp_error<=0;rsp_data<=0;release_pending<=0;clearing<=0;
                    offset_q<=cmd_offset;data_q<=cmd_data;mask_q<=cmd_mask;write_q<=cmd_op==0;
                    case(cmd_op)
                        0,1: begin
                            if(!cleared || cmd_offset>=64'(RAM_BYTES) || cmd_offset[2:0]!=0) begin
                                rsp_error<=1;state<=REPLY;
                            end else state<=ISSUE;
                        end
                        2: begin
                            cleared<=0;clearing<=1;offset_q<=0;data_q<=0;mask_q<=8'hff;write_q<=1;state<=ISSUE;
                        end
                        3: begin
                            rsp_error<=!cleared || cmd_data!=64'h4d494e545352554e;
                            release_pending<=cleared && cmd_data==64'h4d494e545352554e;
                            state<=REPLY;
                        end
                    endcase
                end
                ISSUE: if(memory_bus.ready) state<=WAIT_REPLY;
                WAIT_REPLY: if(memory_bus.rvalid) begin
                    if(clearing && offset_q!=64'(RAM_BYTES-8)) begin
                        offset_q<=offset_q+8;state<=ISSUE;
                    end else begin
                        if(clearing) cleared<=1;
                        rsp_data<=write_q ? 64'd0 : memory_bus.rdata;
                        state<=REPLY;
                    end
                end
                REPLY: if(rsp_ready) begin
                    if(release_pending && !fault) cpu_run<=1;
                    release_pending<=0;state<=IDLE;
                end
            endcase
        end
    end
    // synthesis translate_off
    initial if(RAM_BYTES<8 || RAM_BYTES%8!=0)
        $fatal(1,"boot_memory_loader: RAM_BYTES must be a positive multiple of eight");
    // synthesis translate_on
endmodule
