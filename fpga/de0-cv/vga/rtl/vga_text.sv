// 80x30 text, 8x16 cells, 640x480 active / 800x525 total.
// video_clk is 50 MHz; pixel enables every second cycle give 25 MHz pixels.
// CPU writes the back page; a toggle/ack swaps pages only in vertical blank.
module vga_text #(parameter FONT_HEX="font8x8.hex") (
    input logic cpu_clk, video_clk, rst_n,
    input logic cmd_valid,
    output logic cmd_ready,
    input logic [63:0] cmd_data,
    output logic [63:0] status,
    output logic [3:0] red, green, blue,
    output logic hsync, vsync
);
    (* ramstyle="M10K, no_rw_check" *) logic [7:0] text_ram [0:8191];
    (* ramstyle="M10K" *) logic [7:0] font [0:1023];
    initial $readmemh(FONT_HEX,font);
    logic request, ack, ack_meta, ack_sync, last_ack, back_page;
    logic [31:0] presented;
    wire busy=(request!=ack_sync)||(ack_sync!=last_ack);
    assign cmd_ready=rst_n && !busy;
    assign status={16'h5654,15'b0,busy,presented};
    // No RAM reset: retain dedicated dual-clock M10K inference.
    always_ff @(posedge cpu_clk)
        if(cmd_valid && cmd_ready && !cmd_data[63])
            text_ram[{back_page,cmd_data[11:0]}]<=cmd_data[23:16];
    always_ff @(posedge cpu_clk or negedge rst_n) begin
        if(!rst_n) begin
            request<=0;ack_meta<=0;ack_sync<=0;last_ack<=0;back_page<=1;presented<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(ack_sync!=last_ack) begin
                last_ack<=ack_sync;back_page<=~back_page;presented<=presented+32'd1;
            end
            if(cmd_valid && cmd_ready && cmd_data[63]) request<=~request;
        end
    end
    logic [1:0] reset_pipe;
    always_ff @(posedge video_clk or negedge rst_n)
        if(!rst_n) reset_pipe<=0; else reset_pipe<={reset_pipe[0],1'b1};
    wire video_rst_n=reset_pipe[1];
    logic req_meta,req_sync,front_page,have_frame,phase;
    logic [9:0] x,y;
    logic [7:0] character,glyph;
    logic [2:0] glyph_x;
    logic glyph_green,active_delayed,hs_delayed,vs_delayed,frame_delayed;
    logic [9:0] x_delayed;
    wire [11:0] cell_addr=({7'b0,y[8:4]}<<6)+({7'b0,y[8:4]}<<4)+{5'b0,x[9:3]};
    always_ff @(posedge video_clk) begin
        if(!phase && have_frame) character<=text_ram[{front_page,cell_addr}];
        if(phase && have_frame) glyph<=font[{character[6:0],y[3:1]}];
    end
    always_ff @(posedge video_clk or negedge video_rst_n) begin
        if(!video_rst_n) begin
            req_meta<=0;req_sync<=0;ack<=0;front_page<=0;have_frame<=0;
            phase<=0;x<=0;y<=0;red<=0;green<=0;blue<=0;hsync<=1;vsync<=1;
            glyph_x<=0;glyph_green<=0;active_delayed<=0;hs_delayed<=1;vs_delayed<=1;
            frame_delayed<=0;x_delayed<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;
            phase<=~phase;
            if(phase) begin
                // Character RAM read occurred on the preceding half-pixel.
                glyph_x<=x[2:0];glyph_green<=(character==8'h23);
                active_delayed<=(x<640 && y<480);
                hs_delayed<=!(x>=656 && x<752);vs_delayed<=!(y>=490 && y<492);
                frame_delayed<=have_frame;x_delayed<=x;
                if(x==0 && y==480 && req_sync!=ack) begin
                    front_page<=~front_page;have_frame<=1;ack<=req_sync;
                end
                if(x==799) begin x<=0;if(y==524)y<=0;else y<=y+10'd1;end
                else x<=x+10'd1;
            end else begin
                // Font ROM is synchronous; delay sync/blank/color with it.
                hsync<=hs_delayed;vsync<=vs_delayed;
                red<=0;green<=0;blue<=0;
                if(active_delayed) begin
                    if(!frame_delayed) begin
                        red<={4{x_delayed[8]}};
                        green<={4{x_delayed[7]}};
                        blue<={4{x_delayed[6]}};
                    end else if(glyph[3'd7-glyph_x]) begin
                        red<=glyph_green?4'h0:4'hf;green<=4'hf;blue<=glyph_green?4'h0:4'hf;
                    end
                end
            end
        end
    end
endmodule
