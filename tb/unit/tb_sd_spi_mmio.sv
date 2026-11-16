`timescale 1ns/1ps
module tb_sd_spi_mmio;
    logic clk=0,rst_n=0;always #5 clk=~clk;
    Membus bus();
    wire sclk,mosi,cs_n;
    logic card_miso=1;
`ifdef SD_SPI_BOARD_WRAPPER
    `define SPI_STATE dut.spi
    board_io_mmio dut(.clk(clk),.rst_n(rst_n),.bus(bus),.sd_miso(card_miso),
        .sd_clk(sclk),.sd_mosi(mosi),.sd_cs_n(cs_n),.switches(10'b0),.keys_n(4'hf),
        .leds(),.led_enable(),.video_ready(1'b1),.video_status(64'h5654000000000000),
        .video_valid(),.video_data());
`else
    `define SPI_STATE dut
    sd_spi_mmio #(.HALF_CYCLES(4)) dut(.clk(clk),.rst_n(rst_n),.bus(bus),
        .miso(card_miso),.sclk(sclk),.mosi(mosi),.cs_n(cs_n));
`endif
    byte unsigned reply[$];
    byte unsigned command_bytes[6];
    byte unsigned input_byte=0,output_byte=8'hff;
    int nbit=0,ncmd=0,bytes_seen=0,commands=0;
    bit loopback=0;
    logic [15:0] crc;
    function automatic logic[15:0] crc16(input logic[15:0] c,input byte unsigned d);
        logic[15:0] v;v=c^{d,8'b0};
        repeat(8)v=v[15]?(v<<1)^16'h1021:v<<1;
        return v;
    endfunction
    // Independent byte-level SPI card fixture: command parsing, delayed R1,
    // SDHC init responses and a patterned 512-byte CMD17 block with CRC16.
    always @(posedge sclk) begin
        input_byte={input_byte[6:0],mosi};nbit++;
        if(nbit==8) begin
            nbit=0;bytes_seen++;
            if(!cs_n && !loopback) begin
                if(ncmd>0 || input_byte[7:6]==2'b01) begin
                    command_bytes[ncmd]=input_byte;ncmd++;
                    if(ncmd==6) begin
                        ncmd=0;commands++;reply.push_back(8'hff);
                        case(command_bytes[0])
                            8'h40:begin if(command_bytes[5]!=8'h95)$fatal(1,"CMD0 CRC");reply.push_back(1);end
                            8'h48:begin reply.push_back(1);reply.push_back(0);reply.push_back(0);reply.push_back(1);reply.push_back(8'haa);end
                            8'h77:reply.push_back(1);
                            8'h69:reply.push_back(0);
                            8'h7a:begin reply.push_back(0);reply.push_back(8'hc0);reply.push_back(8'hff);reply.push_back(8'h80);reply.push_back(0);end
                            8'h51:begin
                                if({command_bytes[1],command_bytes[2],command_bytes[3],command_bytes[4]}!=32'd7)$fatal(1,"SDHC sector address");
                                reply.push_back(0);reply.push_back(8'hff);reply.push_back(8'hfe);crc=0;
                                for(int i=0;i<512;i++)begin reply.push_back(8'(i^8'ha5));crc=crc16(crc,8'(i^8'ha5));end
                                reply.push_back(crc[15:8]);reply.push_back(crc[7:0]);
                            end
                            default:$fatal(1,"Unexpected/write card command %h",command_bytes[0]);
                        endcase
                    end
                end
            end
        end
    end
    always @(negedge sclk) begin
        if(nbit==0)begin
            if(reply.size()>0)output_byte=reply.pop_front();else output_byte=8'hff;
        end else output_byte={output_byte[6:0],1'b1};
        if(!loopback)card_miso=cs_n?1'b1:output_byte[7];
    end
    always @(mosi)if(loopback)card_miso=~mosi;
    task automatic access(input bit wr,input int addr,input logic[31:0] data,input logic[7:0] mask,output logic[31:0] result);
        @(negedge clk);bus.valid=1;bus.wen=wr;bus.addr=64'(addr);
`ifdef SD_SPI_BOARD_WRAPPER
        bus.addr=bus.addr+64'd64;
`endif
        bus.wdata=addr[2]?{data,32'b0}:{32'b0,data};bus.wmask=mask;
        do begin @(posedge clk);end while(!bus.ready);
        #1;if(!bus.rvalid)$fatal(1,"missing response");result=addr[2]?bus.rdata[63:32]:bus.rdata[31:0];
        @(negedge clk);bus.valid=0;@(posedge clk);#1;
    endtask
    task automatic wr(input int addr,input logic[31:0] data);logic[31:0] r;access(1,addr,data,addr[2]?8'hf0:8'h0f,r);endtask
    task automatic rd(input int addr,output logic[31:0] data);access(0,addr,0,0,data);endtask
    task automatic xfer(input byte unsigned tx,output byte unsigned rx);
        logic[31:0] s,r;wr(4,{24'b0,tx});
        for(int i=0;i<1000;i++)begin rd(8,s);if(s[7])break;if(i==999)$fatal(1,"transfer timeout");end
        if(s[8] || !s[6] || !s[5])$fatal(1,"status %h",s);
        rd(0,r);rx=r[7:0];rd(8,s);if(s[7])$fatal(1,"RX read didn't clear ready");
    endtask
    task automatic cmd(input byte unsigned op,input logic[31:0] arg,input byte unsigned c,output byte unsigned response);
        byte unsigned r;
        xfer(op,r);xfer(arg[31:24],r);xfer(arg[23:16],r);xfer(arg[15:8],r);xfer(arg[7:0],r);xfer(c,r);
        for(int i=0;i<10;i++)begin xfer(8'hff,response);if(response!=8'hff)return;end
        $fatal(1,"R1 timeout");
    endtask
`ifdef SD_SPI_BOARD_WRAPPER
    localparam time HALF_TIME=250;
`else
    localparam time HALF_TIME=40;
`endif
    realtime last_rise,last_fall;
    always @(posedge sclk) if(rst_n)begin
        if(`SPI_STATE.bit_index!=7 && $realtime-last_fall!=HALF_TIME)$fatal(1,"SCLK low half-period");
        last_rise=$realtime;
    end
    always @(negedge sclk) if(rst_n)begin
        if($realtime-last_rise!=HALF_TIME)$fatal(1,"SCLK high half-period");
        last_fall=$realtime;
    end
    byte unsigned r;logic[31:0] s;logic[15:0] got_crc,expected_crc;
    initial begin
        bus.valid=0;bus.addr=0;bus.wen=0;bus.wmask=0;bus.wdata=0;
        repeat(3)@(posedge clk);#1;if(!cs_n || sclk || !mosi || bus.ready)$fatal(1,"reset outputs");
        @(negedge clk);rst_n=1;
        rd(8,s);if(s!=32'h60)$fatal(1,"reset status");
        // Clocks while deselected are required for SD power-up.
        repeat(10)begin xfer(8'hff,r);if(r!=8'hff || !cs_n)$fatal(1,"unselected clocks");end
        wr(20,1);wr(12,32'h400);if(cs_n)$fatal(1,"CS override");
        // Exhaustive full-duplex bytes, not an SD protocol model assumption.
        loopback=1;card_miso=~mosi;
        for(int i=0;i<256;i++)begin xfer(8'(i),r);if(r!=8'(i^255))$fatal(1,"byte %d rx %h",i,r);end
        // Software errors are visible, and status-clear doesn't lose RX data.
        wr(4,8'h22);wr(4,8'h33);rd(8,s);if(!s[4] || !s[8])$fatal(1,"TX overrun flag");
        do rd(8,s);while(!s[7]);
        wr(8,0);rd(8,s);if(s[8] || !s[7])$fatal(1,"clear error preserves RX ready");
        wr(4,8'h44);do rd(8,s);while(!s[7] || !s[5]);
        if(!s[3] || !s[8])$fatal(1,"RX overrun flag");
        rd(0,s);wr(8,0);rd(8,s);if(s!=32'h60)$fatal(1,"error recovery");
        loopback=0;card_miso=1;ncmd=0;
        cmd(8'h40,0,8'h95,r);if(r!=1)$fatal(1,"CMD0 response");
        cmd(8'h48,32'h1aa,8'h87,r);if(r!=1)$fatal(1,"CMD8");
        xfer(255,r);if(r!=0)$fatal(1,"R7");xfer(255,r);if(r!=0)$fatal(1,"R7");
        xfer(255,r);if(r!=1)$fatal(1,"R7");xfer(255,r);if(r!=8'haa)$fatal(1,"R7");
        cmd(8'h77,0,1,r);if(r!=1)$fatal(1,"CMD55");cmd(8'h69,32'h40000000,1,r);if(r!=0)$fatal(1,"ACMD41");
        cmd(8'h7a,0,1,r);if(r!=0)$fatal(1,"CMD58");repeat(4)xfer(255,r);
        cmd(8'h51,7,1,r);if(r!=0)$fatal(1,"CMD17");
        do xfer(255,r);while(r==255);if(r!=8'hfe)$fatal(1,"read token");expected_crc=0;
        for(int i=0;i<512;i++)begin xfer(255,r);if(r!=8'(i^8'ha5))$fatal(1,"sector byte %d %h",i,r);expected_crc=crc16(expected_crc,r);end
        xfer(255,r);got_crc[15:8]=r;xfer(255,r);got_crc[7:0]=r;if(got_crc!=expected_crc)$fatal(1,"block CRC");
        if(commands!=6)$fatal(1,"command count %d",commands);
        // Partial stores must not mutate control, and held valid cannot duplicate TX.
        access(1,12,0,8'h10,s);rd(12,s);if(s!=32'h400)$fatal(1,"partial control write");
        wr(12,0);if(!cs_n)$fatal(1,"CS release");
        @(negedge clk);bus.valid=1;bus.wen=1;bus.addr=4;
`ifdef SD_SPI_BOARD_WRAPPER
        bus.addr=68;
`endif
        bus.wdata=64'hff00000000;bus.wmask=8'hf0;
        repeat(500)@(posedge clk);
        #1;if(`SPI_STATE.busy || `SPI_STATE.tx_overrun)$fatal(1,"duplicate held-valid TX");
        @(negedge clk);rst_n=0;#1;if(!cs_n || sclk || bus.ready)$fatal(1,"reset while valid");
        $display("SD_SPI_PASS: all bytes, polling ABI/lanes, SDHC init/read/CRC, CS-high clocks, partial stores, held valid and reset");$finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule
