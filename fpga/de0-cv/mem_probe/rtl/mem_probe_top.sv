// mem_probe_top: Quartus analysis-only probe (VIRTUAL_PIN ports; never
// programmed to the board). NBANK independent banks with separate ports so
// that synthesis cannot merge them.
//   ASYNC = 0: ram_1r1w_be64 with STYLE; ASYNC = 1: ram_1r1w_be64_async.
module mem_probe_top #(
    parameter int unsigned DEPTH = 128,
    parameter int unsigned NBANK = 1,
    parameter int unsigned STYLE = 2,
    parameter int unsigned ASYNC = 0
) (
    input  logic                           clk,
    input  logic [NBANK-1:0]               we,
    input  logic [NBANK*$clog2(DEPTH)-1:0] waddr,
    input  logic [NBANK*8-1:0]             wbe,
    input  logic [NBANK*64-1:0]            wdata,
    input  logic [NBANK-1:0]               re,
    input  logic [NBANK*$clog2(DEPTH)-1:0] raddr,
    output logic [NBANK*64-1:0]            rdata
);
    localparam int unsigned AW = $clog2(DEPTH);

    // Explicit generate/endgenerate for Quartus 20.1 Lite (Error 10170 otherwise).
    genvar b;   // declared outside the loop: Quartus 20.1 Lite rejects 'for (genvar ...)'
    generate
    for (b = 0; b < NBANK; b = b + 1) begin : g_bank
        if (ASYNC != 0) begin : g_async
            ram_1r1w_be64_async #(.DEPTH(DEPTH)) u_ram (
                .clk(clk), .we(we[b]), .waddr(waddr[b*AW +: AW]), .wbe(wbe[b*8 +: 8]),
                .wdata(wdata[b*64 +: 64]), .re(re[b]), .raddr(raddr[b*AW +: AW]),
                .rdata(rdata[b*64 +: 64])
            );
        end else begin : g_sync
            ram_1r1w_be64 #(.DEPTH(DEPTH), .STYLE(STYLE)) u_ram (
                .clk(clk), .we(we[b]), .waddr(waddr[b*AW +: AW]), .wbe(wbe[b*8 +: 8]),
                .wdata(wdata[b*64 +: 64]), .re(re[b]), .raddr(raddr[b*AW +: AW]),
                .rdata(rdata[b*64 +: 64])
            );
        end
    end
    endgenerate
endmodule : mem_probe_top
