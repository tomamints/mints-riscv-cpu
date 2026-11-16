// uart_phy: 8N1 TX + RX pair sharing one divisor input (DLL/DLM equivalent).
// TX and RX each own a baud generator and latch the divisor at their own frame
// start, so their frame timing is independent. See uart_tx.sv / uart_rx.sv for
// the byte-interface and timing contracts. Not yet connected to uart_ns16550.
module uart_phy #(
    parameter int unsigned CLK_HZ = 50_000_000,
    parameter int unsigned REF_HZ = 3_686_400
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] divisor,

    input  logic        tx_valid,
    input  logic [7:0]  tx_data,
    output logic        tx_ready,
    output logic        tx_busy,
    output logic        txd,

    input  logic        rxd,
    output logic        rx_valid,
    output logic [7:0]  rx_data,
    output logic        rx_frame_err,
    output logic        rx_break,
    output logic        rx_busy
);

    uart_tx #(
        .CLK_HZ(CLK_HZ),
        .REF_HZ(REF_HZ)
    ) u_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .divisor (divisor),
        .tx_valid(tx_valid),
        .tx_data (tx_data),
        .tx_ready(tx_ready),
        .txd     (txd),
        .tx_busy (tx_busy)
    );

    uart_rx #(
        .CLK_HZ(CLK_HZ),
        .REF_HZ(REF_HZ)
    ) u_rx (
        .clk         (clk),
        .rst_n       (rst_n),
        .divisor     (divisor),
        .rxd         (rxd),
        .rx_valid    (rx_valid),
        .rx_data     (rx_data),
        .rx_frame_err(rx_frame_err),
        .rx_break    (rx_break),
        .rx_busy     (rx_busy)
    );

endmodule : uart_phy
