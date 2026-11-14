// Mode-0, MSB-first, eight-bit SPI host. Polling register subset used by
// Linux 6.12 spi_altera + mmc_spi (no IRQ, DMA or TX FIFO).
// CPU=20 MHz, HALF_CYCLES=25 -> fixed 400 kHz, including SD initialization.
module sd_spi_mmio #(parameter int HALF_CYCLES=25) (
    input logic clk,rst_n,
    Membus.slave bus,
    input logic miso,
    output logic sclk,mosi,cs_n
);
    localparam int DIV_W=$clog2(HALF_CYCLES+1);
    logic [DIV_W-1:0] divider;
    logic [2:0] bit_index;
    logic [7:0] tx_shift,rx_shift,rx_data;
    logic busy,rx_ready,rx_overrun,tx_overrun,sso,selected,wait_low;
    (* async_reg="true" *) logic miso_meta,miso_sync;
    wire fire=bus.valid && bus.ready;
    wire [4:0] reg_addr={bus.addr[4:2],2'b00};
    wire [31:0] w32=bus.addr[2]?bus.wdata[63:32]:bus.wdata[31:0];
    wire lane_ok=bus.addr[1:0]==0 && (bus.addr[2]?bus.wmask[7:4]==4'hf:bus.wmask[3:0]==4'hf);
    logic [31:0] r32;
    assign bus.ready=rst_n && !wait_low;
    assign cs_n=!(selected && sso);
    always_comb begin
        r32=0;
        case(reg_addr)
            0:r32={24'b0,rx_data};
            8:r32={23'b0,(rx_overrun|tx_overrun),rx_ready,!busy,!busy,tx_overrun,rx_overrun,3'b0};
            12:r32={21'b0,sso,10'b0};
            20:r32={31'b0,selected};
            default:;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            divider<=0;bit_index<=0;tx_shift<=8'hff;rx_shift<=0;rx_data<=0;
            busy<=0;rx_ready<=0;rx_overrun<=0;tx_overrun<=0;sso<=0;selected<=0;
            wait_low<=0;bus.rvalid<=0;bus.rdata<=0;
            sclk<=0;mosi<=1;miso_meta<=1;miso_sync<=1;
        end else begin
            miso_meta<=miso;miso_sync<=miso_meta;
            if(!bus.valid)wait_low<=0;
            bus.rvalid<=fire;
            if(fire) begin
                wait_low<=1;
                bus.rdata<=bus.addr[2]?{r32,32'b0}:{32'b0,r32};
                if(!bus.wen && reg_addr==0)rx_ready<=0;
                if(bus.wen && lane_ok) begin
                    case(reg_addr)
                        4:if(!busy) begin
                            busy<=1;sclk<=0;divider<=DIV_W'(HALF_CYCLES-1);
                            bit_index<=7;tx_shift<=w32[7:0];mosi<=w32[7];rx_shift<=0;
                        end else tx_overrun<=1;
                        8:begin rx_overrun<=0;tx_overrun<=0;end
                        12:sso<=w32[10];
                        20:selected<=w32[0];
                        default:;
                    endcase
                end
            end
            if(busy) begin
                if(divider!=0)divider<=divider-1'b1;
                else begin
                    divider<=DIV_W'(HALF_CYCLES-1);sclk<=~sclk;
                    if(!sclk)rx_shift<={rx_shift[6:0],miso_sync};
                    else if(bit_index==0) begin
                        busy<=0;rx_data<=rx_shift;rx_ready<=1;mosi<=1;
                        if(rx_ready && !(fire && !bus.wen && reg_addr==0))rx_overrun<=1;
                    end else begin
                        bit_index<=bit_index-1'b1;tx_shift<={tx_shift[6:0],1'b1};mosi<=tx_shift[6];
                    end
                end
            end
        end
    end
endmodule
