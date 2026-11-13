`timescale 1ns/1ps
// Board-path simulation of de0cv_soc_core: a JTAG-scan model loads a RAM image
// through jtag_block_mailbox -> boot_memory_loader -> membus_sdram_adapter ->
// sdram_bridge64 -> sdram_native16 -> sdram_cycle_model16 (CLEAR of all
// 64 MiB, WRITE, READ-back compare, RELEASE), then the CPU runs it from the
// boot ROM and the UART TX pin is decoded at 115200 8N1 until the image
// prints PASS_TEXT (pass) or FAIL_TEXT (fail).
//   +IMAGE=<words file>  lines "<word index hex> <value hex>" (sorted)
//   +ROM is the core parameter BOOTROM_HEX (set at build time)
module tb_de0cv_soc #(
    parameter BOOTROM_HEX = "bootrom_linux.hex"
);
    localparam real CLK_HALF = 25.0;    // 20 MHz
    localparam real TCK_HALF = 83.0;    // ~6 MHz
    localparam int unsigned WORDS = 1024;
    localparam logic [63:0] RUN = 64'h4d494e545352554e;
    localparam string PASS_TEXT = "SELFTEST PASS";
    localparam string FAIL_TEXT = "FAIL";

    logic clk = 0, tck = 0, power_n = 0;
    always #(CLK_HALF) clk = ~clk;
    logic tdi = 0, cdr = 0, sdr = 0, udr = 0;
    logic [1:0] vir = 0;
    wire tdo;
    wire [9:0] ledr;
    wire txd;
    wire [12:0] a;
    wire [1:0] ba;
    wire cke, csn, rasn, casn, wen, ldqm, udqm;
    wire [15:0] dq;
    logic [15:0] model_dq;

    de0cv_soc_core #(.BOOTROM_HEX(BOOTROM_HEX), .MAILBOX_WORDS(WORDS)) dut (
        .clk(clk), .power_n(power_n), .locked(1'b1),
        .tck(tck), .tdi(tdi), .cdr(cdr), .sdr(sdr), .udr(udr), .vir(vir), .tdo(tdo),
        .LEDR(ledr), .SW(10'b0), .KEY_N(4'hf), .UART_RXD(1'b1), .UART_TXD(txd),
        .DRAM_ADDR(a), .DRAM_BA(ba), .DRAM_CKE(cke), .DRAM_CS_N(csn), .DRAM_RAS_N(rasn),
        .DRAM_CAS_N(casn), .DRAM_WE_N(wen), .DRAM_LDQM(ldqm), .DRAM_UDQM(udqm), .DRAM_DQ(dq)
    );
    // Board DQ: the controller drives it when dq_oe, the SDRAM otherwise.
    assign dq = dut.dq_oe ? 16'hzzzz : model_dq;
    sdram_cycle_model16 #(.CLK_HZ(20_000_000), .UNWRITTEN(16'hdead)) sdram (
        .clk(clk), .rst_n(power_n), .a(a), .ba(ba), .dqm({udqm, ldqm}), .cke(cke), .csn(csn),
        .rasn(rasn), .casn(casn), .wen(wen), .oe(dut.dq_oe), .dout(dut.dq_out), .din(model_dq)
    );

    // ---------------- UART TX decoder (115200 8N1 at 20 MHz) ----------------
    localparam real BIT_NS = 1.0e9 / 115200.0;
    string uart_text = "";
    initial begin
        forever begin
            logic [7:0] ch;
            @(negedge txd);
            #(BIT_NS * 1.5);
            for (int i = 0; i < 8; i++) begin ch[i] = txd; #(BIT_NS); end
            if (!txd) $fatal(1, "UART framing error");
            $write("%c", ch);
            uart_text = {uart_text, string'(ch)};
        end
    end
    function automatic bit contains(input string s, input string pat);
        if (s.len() < pat.len()) return 0;
        for (int i = 0; i + pat.len() <= s.len(); i++) if (s.substr(i, i + pat.len() - 1) == pat) return 1;
        return 0;
    endfunction

    // ---------------- JTAG scan model (as tb_jtag_block_mailbox) ----------------
    task automatic tck_cycle();
        #(TCK_HALF) tck = 1; #(TCK_HALF) tck = 0;
    endtask
    task automatic scan(input logic [1:0] sel, input int n, input logic [63:0] tx [], output logic [63:0] rx []);
        rx = new[(n + 63) / 64];
        vir = sel;
        tck_cycle();
        cdr = 1; tck_cycle(); cdr = 0;
        sdr = 1;
        for (int i = 0; i < n; i++) begin
            tdi = (i / 64 < tx.size()) ? tx[i / 64][i % 64] : 1'b0;
            rx[i / 64][i % 64] = tdo;
            tck_cycle();
        end
        sdr = 0; tck_cycle();
        udr = 1; tck_cycle(); udr = 0;
        tck_cycle(); tck_cycle();
    endtask
    logic [63:0] none [];
    task automatic status(output logic [63:0] s);
        logic [63:0] rx [];
        scan(2'd0, 64, none, rx); s = rx[0];
        if (s[63:48] != 16'h4A4D) $fatal(1, "bad status %h", s);
    endtask
    task automatic command(input logic [1:0] op, input int count, input logic [31:0] woff, output logic [63:0] s);
        logic [63:0] tx [], rx [];
        tx = new[1]; tx[0] = {16'h4A42, woff, 14'(count), op};
        scan(2'd1, 64, tx, rx);
        do begin
            repeat (200) tck_cycle();
            status(s);
        end while (s[0] != s[1]);
        if (s[2] || s[10] || s[11] || s[5] || s[6] || (op != 2'd2 && op != 2'd3 && s[47:32] != 16'(count)))
            $fatal(1, "command op=%0d count=%0d offset=%h failed: status %h", op, count, woff, s);
    endtask

    // image: sparse words, grouped into contiguous blocks of at most WORDS
    logic [31:0] img_idx [$];
    logic [63:0] img_val [$];
    task automatic read_image(input string path);
        int fd, n;
        logic [31:0] i; logic [63:0] v;
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "cannot open %s", path);
        while ($fscanf(fd, "%h %h\n", i, v) == 2) begin img_idx.push_back(i); img_val.push_back(v); end
        $fclose(fd);
        if (img_idx.size() == 0) $fatal(1, "empty image");
    endtask
    task automatic for_each_block(input bit write);
        int k = 0;
        while (k < img_idx.size()) begin
            int n = 1;
            logic [63:0] blk [], back [], tx [], s;
            while (k + n < img_idx.size() && n < WORDS && img_idx[k + n] == img_idx[k] + n) n++;
            blk = new[n];
            for (int j = 0; j < n; j++) blk[j] = img_val[k + j];
            if (write) begin
                scan(2'd2, 64 * n, blk, back);
                command(2'd0, n, img_idx[k], s);
            end else begin
                command(2'd1, n, img_idx[k], s);
                tx = new[0];
                scan(2'd2, 64 * n, tx, back);
                for (int j = 0; j < n; j++)
                    if (back[j] !== blk[j]) $fatal(1, "readback word %h: %h != %h", img_idx[k] + j, back[j], blk[j]);
            end
            k += n;
        end
    endtask

    string image;
    logic [63:0] s, blk [], back [];
    realtime t0;
    initial begin
        if (!$value$plusargs("IMAGE=%s", image)) $fatal(1, "+IMAGE=<words file> required");
        read_image(image);
        repeat (20) @(posedge clk); power_n = 1;
        wait (ledr[4]);   // SDRAM init done
        repeat (5) tck_cycle();
        status(s);
        if (s[3] || s[4]) $fatal(1, "initial status %h", s);
        t0 = $realtime;
        command(2'd2, 0, 0, s);                         // CLEAR all 64 MiB
        if (!s[3] || !ledr[2]) $fatal(1, "not cleared: %h", s);
        $display("[TB] clear done in %0.1f ms simulated", ($realtime - t0) / 1e6);
        for_each_block(1);
        for_each_block(0);
        $display("[TB] %0d image words written and verified", img_idx.size());
        if (ledr[3]) $fatal(1, "CPU running before release");
        blk = new[1]; blk[0] = RUN;
        scan(2'd2, 64, blk, back);
        command(2'd3, 0, 0, s);
        if (!s[4] || !ledr[3]) $fatal(1, "CPU not released: %h", s);
        $display("[TB] CPU released");
        t0 = $realtime;
        while (!contains(uart_text, PASS_TEXT) && !contains(uart_text, FAIL_TEXT)) begin
            #(1ms);
            if ($realtime - t0 > 500ms) $fatal(1, "UART timeout");
            if (ledr[5] || ledr[6]) $fatal(1, "memory/loader fault LEDR=%b", ledr);
        end
        #(BIT_NS * 40);
        if (contains(uart_text, FAIL_TEXT)) $fatal(1, "image reported FAIL");
        $display("\nDE0CV_SOC_SIM_PASS");
        $finish;
    end
endmodule
