// Board GPIO/video at +0..31; SPI polling registers at +64..87.
module board_io_mmio (
    input logic clk,rst_n,
    input logic [9:0] switches,
    input logic [3:0] keys_n,
    output logic [9:0] leds,
    output logic led_enable,
    input logic video_ready,
    input logic [63:0] video_status,
    output logic video_valid,
    output logic [63:0] video_data,
    input logic sd_miso,
    output logic sd_clk,sd_mosi,sd_cs_n,
    Membus.slave bus
);
    Membus gpio_bus(),spi_bus();
    wire spi_select=bus.addr[6];
    logic reserved_rvalid;
    wire reserved= !spi_select && bus.addr[5];
    assign gpio_bus.valid=bus.valid && !spi_select && !reserved;
    assign spi_bus.valid=bus.valid && spi_select;
    assign gpio_bus.addr=bus.addr;assign spi_bus.addr=bus.addr-64'd64;
    assign gpio_bus.wen=bus.wen;assign spi_bus.wen=bus.wen;
    assign gpio_bus.wdata=bus.wdata;assign spi_bus.wdata=bus.wdata;
    assign gpio_bus.wmask=bus.wmask;assign spi_bus.wmask=bus.wmask;
    assign bus.ready=reserved?rst_n:(spi_select?spi_bus.ready:gpio_bus.ready);
    assign bus.rvalid=gpio_bus.rvalid|spi_bus.rvalid|reserved_rvalid;
    assign bus.rdata=spi_bus.rvalid?spi_bus.rdata:(gpio_bus.rvalid?gpio_bus.rdata:64'b0);
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)reserved_rvalid<=0;else reserved_rvalid<=bus.valid && bus.ready && reserved;
    board_gpio_mmio #(.VGA_ENABLED(1)) gpio(.*,.bus(gpio_bus));
    sd_spi_mmio spi(.clk(clk),.rst_n(rst_n),.bus(spi_bus),.miso(sd_miso),
        .sclk(sd_clk),.mosi(sd_mosi),.cs_n(sd_cs_n));
endmodule
