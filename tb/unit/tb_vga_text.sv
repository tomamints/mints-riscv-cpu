`timescale 1ns/1ps
module tb_vga_text;
    logic cpu_clk=0,video_clk=0,rst_n=0;
    always #25 cpu_clk=~cpu_clk;
    always #10 video_clk=~video_clk;
    logic valid=0;logic[63:0] data=0,status;wire ready;
    wire[3:0] r,g,b;wire hs,vs;
    vga_text #(.FONT_HEX("fpga/de0-cv/vga/font8x8.hex")) dut(
        .cpu_clk(cpu_clk),.video_clk(video_clk),.rst_n(rst_n),.cmd_valid(valid),.cmd_ready(ready),
        .cmd_data(data),.status(status),.red(r),.green(g),.blue(b),.hsync(hs),.vsync(vs));
    task automatic command(input logic[63:0] value);
        @(negedge cpu_clk);data=value;valid=1;
        do begin @(posedge cpu_clk);end while(!ready);
        @(negedge cpu_clk);valid=0;
    endtask
    task automatic wait_present(input logic[31:0] count);
        wait(status[31:0]==count && !status[32]);
    endtask
    int frames=0,pixels=0,hs_low=0,vs_low=0,active=0,lit=0;
    bit capture=0;
    integer file;
    // Sample only emitted pixels, after the synchronous font pipeline.
    always @(posedge video_clk) begin
        bit output_cycle;
        output_cycle=dut.video_rst_n && !dut.phase;
        #1;
        if(output_cycle) begin
            if(dut.frame_delayed && dut.x_delayed==0 && dut.y==0) begin end
            if(capture) begin
                pixels++;
                if(!hs)hs_low++;
                if(!vs)vs_low++;
                if(dut.active_delayed)begin
                    active++;if({r,g,b}!=0)lit++;
                    $fwrite(file,"%c%c%c",{r,r},{g,g},{b,b});
                end else if({r,g,b}!=0)$fatal(1,"RGB outside visible region");
                if(pixels==800*525) begin
                    capture=0;$fclose(file);
                    if(hs_low!=96*525 || vs_low!=2*800 || active!=640*480 || lit==0)
                        $fatal(1,"timing/pixels: %d %d %d %d",hs_low,vs_low,active,lit);
                    frames++;
                end
            end
        end
        // With a bank ownership handshake no read and write may target one page.
        if(rst_n && dut.cmd_valid && dut.cmd_ready && !dut.cmd_data[63] && dut.have_frame)
            if(dut.back_page==dut.front_page)$fatal(1,"front page written");
    end
    initial begin
        #200;rst_n=1;
        for(int i=0;i<2400;i++)command(64'(i)|(64'h20<<16));
        command(64'(80+4)|(64'h4d<<16)); // M
        command(64'(80+5)|(64'h49<<16)); // I
        command(64'(80+6)|(64'h4e<<16)); // N
        command(64'(80+7)|(64'h54<<16)); // T
        command(64'(80+8)|(64'h53<<16)); // S
        command(64'(80*4+20)|(64'h23<<16));
        command(64'h8000000000000000);
        if(ready)$fatal(1,"commit did not exert backpressure");
        repeat(100)@(posedge cpu_clk);
        if(ready || dut.have_frame)$fatal(1,"swap occurred outside vblank");
        wait_present(1);
        if(dut.front_page!=1 || dut.back_page!=0)$fatal(1,"bank exchange");
        // Change the back page; current visible text must stay intact.
        command(64'(80+4)|(64'h58<<16));
        if(dut.text_ram[4096+84]!=8'h4d)$fatal(1,"front RAM modified");
        wait(dut.x==0 && dut.y==0 && dut.phase==1);@(posedge video_clk);#2;
        file=$fopen("build/test/vga/frame.ppm","wb");
        $fwrite(file,"P6\n640 480\n255\n");capture=1;
        wait(frames==1);
        // Complete the other page before presenting it.
        for(int i=0;i<2400;i++)command(64'(i)|(64'h23<<16));
        command(64'h8000000000000000);wait_present(2);
        if(dut.front_page!=0 || dut.back_page!=1)$fatal(1,"second exchange");
        $display("VGA_TEXT_PASS: full-frame sync/blanking, text pixels, double-buffer ownership and ack");$finish;
    end
    initial begin #100000000;$fatal(1,"timeout");end
endmodule
