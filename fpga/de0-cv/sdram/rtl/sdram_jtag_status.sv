// Read-only status/diagnostics. Status flags and failure records are stable on
// completion. Host must wait for a valid magic and read stable completion flags.
module sdram_jtag_status(input wire [31:0] status,
    input wire [63:0] failed_addr,failed_expected,failed_actual);
    wire tck,tdi,capture,shift;
    wire [1:0] ir;
    reg [31:0] meta=0,sync=0,serial=0;
    sld_virtual_jtag #(.sld_auto_instance_index("NO"),.sld_instance_index(0),.sld_ir_width(2))
        u_jtag(.tck(tck),.tdi(tdi),.tdo(serial[0]),.ir_in(ir),.ir_out(2'b0),
            .virtual_state_cdr(capture),.virtual_state_sdr(shift));
    always @(posedge tck) begin
        meta<=status; sync<=meta;
        if(capture) begin
            case(ir)
                0: serial<=sync;
                1: serial<=failed_addr[31:0];
                2: serial<=failed_expected[31:0];
                3: serial<=failed_actual[31:0];
            endcase
        end else if(shift) serial<={tdi,serial[31:1]};
    end
endmodule
