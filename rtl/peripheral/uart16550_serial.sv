// Physical serial backend for the Membus 16550 register block.
// One system clock; the PHY uses clock enables, with no UART clock domain.
// Device-tree clock-frequency must equal REF_HZ, not CLK_HZ. The fractional
// reference enable generator permits the same divisors at 20 and 50 MHz.
module uart16550_serial #(
    parameter int unsigned CLK_HZ = 20_000_000,
    parameter int unsigned REF_HZ = 3_686_400
) (
    input logic clk, rst,
    Membus.slave membus,
    input logic rxd,
    output logic txd, irq,
    output logic diag_tx_overflow, diag_rx_overrun
);
    logic [15:0] divisor;
    logic tx_valid, tx_ready, tx_busy;
    logic [7:0] tx_data, rx_data;
    logic rx_valid, rx_fe, rx_bi;
    uart16550_regs regs (
        .clk(clk), .rst(rst), .membus(membus), .irq(irq), .divisor(divisor),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy),
        .rx_push(rx_valid), .rx_data(rx_data), .rx_fe(rx_fe), .rx_bi(rx_bi),
        .rx_space(), .diag_tx_overflow(diag_tx_overflow), .diag_rx_overrun(diag_rx_overrun)
    );
    uart_phy #(.CLK_HZ(CLK_HZ), .REF_HZ(REF_HZ)) phy (
        .clk(clk), .rst_n(rst), .divisor(divisor),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy),
        .txd(txd), .rxd(rxd), .rx_valid(rx_valid), .rx_data(rx_data),
        .rx_frame_err(rx_fe), .rx_break(rx_bi), .rx_busy()
    );
endmodule
