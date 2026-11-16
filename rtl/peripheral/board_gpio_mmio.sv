// DE0-CV board-only replacement for the eight-byte simulation debug window.
// Read: [63:48] ID=4d47, [35:32] pressed keys, [25:16] switches,
//       [10] application LED ownership, [9:0] application LED values.
// Write: only bytes 0/1 affect the low eleven control bits. No IRQ/debounce.
module board_gpio_mmio #(parameter bit VGA_ENABLED=0) (
    input logic clk, rst_n,
    input logic [9:0] switches,
    input logic [3:0] keys_n,
    output logic [9:0] leds,
    output logic led_enable,
    input logic video_ready,
    input logic [63:0] video_status,
    output logic video_valid,
    output logic [63:0] video_data,
    Membus.slave bus
);
    logic [9:0] sw_meta, sw_sync;
    logic [3:0] key_meta, key_sync;
    assign video_valid=rst_n && VGA_ENABLED && bus.valid && bus.wen && bus.addr[4:3]==1 && bus.wmask==8'hff;
    assign video_data=bus.wdata;
    assign bus.ready = rst_n && !(video_valid && !video_ready);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw_meta <= '0; sw_sync <= '0;
            key_meta <= '1; key_sync <= '1;
            leds <= '0; led_enable <= 1'b0;
            bus.rvalid <= 1'b0; bus.rdata <= '0;
        end else begin
            sw_meta <= switches; sw_sync <= sw_meta;
            key_meta <= keys_n; key_sync <= key_meta;
            bus.rvalid <= bus.valid && bus.ready;
            if (bus.valid && bus.ready) begin
                case(bus.addr[4:3])
                    0: bus.rdata <= {16'h4d47,VGA_ENABLED,11'b0,~key_sync,6'b0,sw_sync,5'b0,led_enable,leds};
                    2: bus.rdata <= VGA_ENABLED ? video_status : 64'b0;
                    default: bus.rdata <= 0;
                endcase
                if (bus.wen && bus.addr[4:3]==0) begin
                    if (bus.wmask[0]) leds[7:0] <= bus.wdata[7:0];
                    if (bus.wmask[1]) begin
                        leds[9:8] <= bus.wdata[9:8];
                        led_enable <= bus.wdata[10];
                    end
                end
            end
        end
    end
endmodule
