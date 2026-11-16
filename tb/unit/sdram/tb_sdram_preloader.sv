`timescale 1ns/1ps
// Unit TB for tb/model/sdram_preloader.sv with a scripted Membus slave.
// The runner sets RAM_FILE_PATH and plusargs per case:
//   (default)          sparse image: exactly the non-zero words are written, in
//                      order, mask ff, offset = index*8; no request in reset;
//                      valid/payload stable until ready; nothing after done;
//   +SDRAM_PRELOAD_VERIFY            + every written word is read back;
//   +SDRAM_PRELOAD_VERIFY +CORRUPT_READ  one readback is corrupted -> fatal;
//   +RESET_AGAIN       a second reset after the preload -> fatal (reload);
//   missing/unset RAM_FILE_PATH (runner)                  -> fatal.
// The reset sequence mirrors the CPU testbench: rst high, low, high.
module tb_sdram_preloader;
    localparam int unsigned WORDS = 4096;
    logic clk = 0; always #5 clk = ~clk;
    logic rst;
    bit start_low;
    bit released = 0;          // first release after an assertion (TB view)
    initial begin
        start_low = $test$plusargs("START_LOW");
        rst = start_low ? 1'b0 : 1'b1;        // CPU TB profile starts high
    end
    logic done;
    Membus bus();
    sdram_preloader #(.FILEPATH_IS_ENV(1), .FILEPATH("RAM_FILE_PATH"), .WORDS(WORDS)) dut(
        .clk(clk), .rst(rst), .done(done), .bus(bus));

    // reference image (parsed independently of the preloader's queue)
    logic [63:0] ref_img [0:WORDS-1];
    int unsigned expect_idx [$];
    initial begin
        string path;
        if ($value$plusargs("IMAGE=%s", path)) begin
            for (int unsigned i = 0; i < WORDS; i++) ref_img[i] = '0;
            $readmemh(path, ref_img);
            for (int unsigned i = 0; i < WORDS; i++) if (ref_img[i] != 0) expect_idx.push_back(i);
        end
    end

    // scripted slave
    logic [63:0] rng = 64'h2026_1110_9E1D_0001;
    function automatic logic [63:0] xs(input logic [63:0] s);
        logic [63:0] x; x = s; x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x;
    endfunction
    logic s_ready = 0, s_rvalid = 0; logic [63:0] s_rdata = '0;
    assign bus.ready = s_ready; assign bus.rvalid = s_rvalid; assign bus.rdata = s_rdata;
    logic [63:0] store [logic [63:0]];
    bit busy = 0; int wait_n = 0; logic [63:0] rsp_word;
    int unsigned n_writes = 0, n_reads = 0, n_corrupt = 0;
    bit corrupt; initial corrupt = $test$plusargs("CORRUPT_READ");
    logic prev_valid = 0; logic [63:0] prev_addr, prev_wdata; logic prev_wen; logic [7:0] prev_wmask;
    bit prev_ready = 0;

    always @(posedge clk) begin
        if (!rst && bus.valid) $fatal(1, "[RESET] request while rst is asserted");
        if (!released && (bus.valid || done)) $fatal(1, "[START] request/done before the first proper reset release");
        if (done && bus.valid) $fatal(1, "[DONE] request after done");
        // R1 hold: a request not accepted must stay identical
        if (prev_valid && !prev_ready && rst &&
            (!bus.valid || bus.addr !== prev_addr || bus.wen !== prev_wen || bus.wdata !== prev_wdata || bus.wmask !== prev_wmask))
            $fatal(1, "[HOLD] request changed or withdrawn before acceptance");
        prev_valid = bus.valid; prev_ready = bus.ready; prev_addr = bus.addr; prev_wen = bus.wen;
        prev_wdata = bus.wdata; prev_wmask = bus.wmask;
        s_rvalid <= 0;
        if (busy) begin
            if (wait_n == 0) begin
                s_rvalid <= 1;
                s_rdata <= store.exists(rsp_word) ? store[rsp_word] : 64'hdead_beef_dead_beef;
                if (corrupt && n_reads == 3 && n_corrupt == 0) begin s_rdata <= 64'h1; n_corrupt++; end
                busy = 0;
            end else wait_n--;
        end
        if (bus.valid && bus.ready) begin
            if (bus.wen) begin
                int unsigned k;
                if (bus.wmask !== 8'hff) $fatal(1, "[WRITE] mask %h", bus.wmask);
                if (n_writes >= expect_idx.size()) $fatal(1, "[WRITE] more writes than non-zero words");
                k = expect_idx[n_writes];
                if (bus.addr !== 64'(k) * 8 || bus.wdata !== ref_img[k])
                    $fatal(1, "[WRITE] #%0d addr %h data %h, expected %h / %h", n_writes, bus.addr, bus.wdata, 64'(k) * 8, ref_img[k]);
                store[bus.addr] = bus.wdata; n_writes++;
            end else begin
                n_reads++;
            end
            rsp_word = bus.addr; busy = 1; wait_n = int'(rng % 4); rng = xs(rng);
        end
        // registered: depends on handshake state (permitted), never combinationally on valid
        s_ready <= !busy && !(bus.valid && bus.ready) && rng[7:0] < 8'd160;
        rng = xs(rng);
    end

    initial begin
        #1;
        repeat (6) @(posedge clk);          // initial phase: no request may appear
        if (!start_low) begin @(negedge clk); rst = 0; end
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1; released = 1;
        wait (done);
        repeat (20) @(posedge clk);
        if (n_writes != expect_idx.size()) $fatal(1, "[COUNT] writes %0d expected %0d", n_writes, expect_idx.size());
        if ($test$plusargs("SDRAM_PRELOAD_VERIFY") && n_reads != expect_idx.size())
            $fatal(1, "[COUNT] reads %0d expected %0d", n_reads, expect_idx.size());
        if ($test$plusargs("RESET_AGAIN")) begin
            @(negedge clk); rst = 0;            // must be fatal in the preloader
            repeat (5) @(posedge clk);
            $display("RESET_AGAIN_NOT_REJECTED");
            $finish;
        end
        $display("SDRAM_PRELOADER_PASS writes=%0d reads=%0d", n_writes, n_reads);
        $finish;
    end
    initial begin #50_000_000; $fatal(1, "[WATCHDOG] writes=%0d", n_writes); end
endmodule
