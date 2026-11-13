// DE0-CV board-only replacement for the eight-byte simulation debug window.
// Read: [63:48] ID=4d47, [35:32] pressed keys, [25:16] switches,
//       [10] application LED ownership, [9:0] application LED values.
// Write: only bytes 0/1 affect the low eleven control bits. No IRQ/debounce.
module board_gpio_mmio (
    input logic clk, rst_n,
    input logic [9:0] switches,
    input logic [3:0] keys_n,
    output logic [9:0] leds,
    output logic led_enable,
    Membus.slave bus
);
    logic [9:0] sw_meta, sw_sync;
    logic [3:0] key_meta, key_sync;
    assign bus.ready = rst_n;
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
                bus.rdata <= {16'h4d47, 12'b0, ~key_sync, 6'b0, sw_sync, 5'b0, led_enable, leds};
                if (bus.wen) begin
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
