`timescale 1ns/1ps
module tb_vga_mmio;
    logic clk=0,rst_n=0,video_ready=1;
    always #5 clk=~clk;
    logic [63:0] video_status=64'h5654000000000123,video_data;
    wire video_valid;wire[9:0]leds;
    wire led_enable;
    Membus bus();
    board_gpio_mmio #(.VGA_ENABLED(1)) dut(.clk(clk),.rst_n(rst_n),.switches(10'b0),.keys_n(4'hf),
        .leds(leds),.led_enable(led_enable),.bus(bus),.video_ready(video_ready),
        .video_status(video_status),.video_valid(video_valid),.video_data(video_data));
    task automatic tick;@(posedge clk);#1;endtask
    task automatic read_word(input logic[63:0] addr,input logic[63:0] expected);
        @(negedge clk);bus.valid=1;bus.wen=0;bus.addr=addr;
        tick();if(!bus.rvalid || bus.rdata!=expected)$fatal(1,"read %h -> %h",addr,bus.rdata);
        @(negedge clk);bus.valid=0;tick();
    endtask
    initial begin
        bus.valid=1;bus.wen=1;bus.addr=8;bus.wdata=64'h123400;bus.wmask=8'hff;
        tick();if(video_valid || bus.ready || bus.rvalid)$fatal(1,"transfer during reset");
        @(negedge clk);bus.valid=0;rst_n=1;tick();
        read_word(0,64'h4d47800000000000);
        read_word(16,video_status);
        @(negedge clk);video_ready=0;bus.valid=1;bus.wen=1;bus.addr=8;bus.wdata=64'h8000000000000000;
        repeat(4) begin tick();if(bus.ready || bus.rvalid || !video_valid || video_data!=bus.wdata)$fatal(1,"backpressure");end
        @(negedge clk);video_ready=1;tick();if(!bus.rvalid || !video_valid)$fatal(1,"missing accepted command");
        @(negedge clk);bus.valid=0;tick();if(bus.rvalid || video_valid)$fatal(1,"duplicate command");
        @(negedge clk);video_ready=0;bus.valid=1;bus.wen=1;bus.addr=8;bus.wmask=3;
        tick();if(!bus.ready || !bus.rvalid || video_valid)$fatal(1,"partial command not ignored");
        @(negedge clk);bus.addr=0;bus.wmask=3;bus.wdata=64'h555;
        tick();if(leds!=10'h155 || !led_enable || !bus.rvalid)$fatal(1,"GPIO blocked by video");
        @(negedge clk);rst_n=0;bus.addr=8;bus.wmask=8'hff;video_ready=1;#1;
        if(video_valid || bus.ready || led_enable)$fatal(1,"reset ownership");
        $display("VGA_MMIO_PASS: reset, full-word commands, status, GPIO independence and backpressure");$finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
