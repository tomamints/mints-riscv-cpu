`timescale 1ns/1ps
module tb_board_gpio;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [9:0] sw=0;
    logic [3:0] keys_n='1;
    logic [9:0] leds;
    logic enable;
    Membus bus();
    board_gpio_mmio dut(.clk(clk), .rst_n(rst_n), .switches(sw), .keys_n(keys_n),
        .video_ready(1'b1),.video_status(64'b0),.video_valid(),.video_data(),
        .leds(leds), .led_enable(enable), .bus(bus));
    task automatic tick;
        @(posedge clk); #1;
    endtask
    task automatic access(input bit wr, input logic[63:0] data, input logic[7:0] mask,
                          output logic[63:0] value);
        @(negedge clk); bus.valid=1; bus.wen=wr; bus.wdata=data; bus.wmask=mask;
        tick(); if(!bus.rvalid) $fatal(1,"missing response"); value=bus.rdata;
        @(negedge clk); bus.valid=0;
        tick(); if(bus.rvalid) $fatal(1,"duplicate response");
    endtask
    logic [63:0] value;
    initial begin
        bus.valid=0; bus.wen=0; bus.addr=0; bus.wdata=0; bus.wmask=0;
        tick(); if(bus.ready || bus.rvalid || enable || leds) $fatal(1,"reset");
        @(negedge clk); rst_n=1;
        access(0,0,0,value);
        if(value != 64'h4d47000000000000) $fatal(1,"ID/reset %h", value);
        // Both input banks change between edges: no combinational exposure.
        @(negedge clk); sw=10'h2ab; keys_n=4'b1010;
        if(dut.sw_sync != 0 || dut.key_sync != 4'hf) $fatal(1,"combinational inputs");
        tick(); if(dut.sw_sync != 0 || dut.key_sync != 4'hf) $fatal(1,"one-stage CDC");
        tick();
        access(0,0,0,value);
        if(value[25:16] != sw || value[35:32] != 4'b0101) $fatal(1,"inputs %h",value);
        for(int mask=0;mask<256;mask++) begin
            access(1,64'hffffffffffffffff,8'(mask),value);
            if(leds != {2'((mask>>1)&1 ? 3:0),8'(mask&1 ? 255:0)} || enable != ((mask>>1)&1))
                $fatal(1,"byte enable %0d leds=%h enable=%b",mask,leds,enable);
            access(0,0,0,value);
            if(value[63:48]!=16'h4d47 || value[35:32]!=5 || value[25:16]!=sw)
                $fatal(1,"RO input/ID modified");
            access(1,0,8'hff,value);
        end
        access(1,64'h555,3,value);
        if(leds!=10'h155 || !enable) $fatal(1,"control");
        @(negedge clk); rst_n=0; #1;
        if(enable || leds || bus.rvalid) $fatal(1,"reset did not release LED owner");
        $display("BOARD_GPIO_PASS: CDC, all byte masks, RO fields, reset and responses");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
