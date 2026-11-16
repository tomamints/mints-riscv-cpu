import util::*;

// Simulation-only RAM image preloader for the SDRAM backend (C3 M3b).
// Loads the same 64-bit-word hex file as `memory` (RAM_FILE_PATH), then writes
// every non-zero word through its Membus master port (the adapter's upstream)
// with full byte masks, one outstanding request, holding valid and payload
// until ready (C3 R1). Optionally reads every word back (+SDRAM_PRELOAD_VERIFY).
// `done` rises after the last response and stays high; top.sv then hands the
// adapter to the CPU RAM port. Words that are zero are not written: the cycle
// model's UNWRITTEN value must be 0 in this configuration (like `memory`); a
// physical board loader cannot rely on that and must write or clear memory.
// Guards: the image is required (unset/empty RAM_FILE_PATH or an unopenable
// file is fatal); no request while rst is asserted; single cold start only -
// the model keeps its contents across rst and zero words are skipped, so a
// second reset (reload) is fatal instead of silently loading over old data.
// The CPU waits on RAM backpressure during the preload (simulation profile
// only): its timers/counters run meanwhile, so execution budgets must exclude
// the reported preload cycles. On the board the CPU stays in reset until the
// loader has verified the image.
module sdram_preloader #(
    parameter bit          FILEPATH_IS_ENV = 1,
    parameter string       FILEPATH        = "RAM_FILE_PATH",
    parameter int unsigned WORDS           = 1 << 23     // 64 MiB of 64-bit words
) (
    input  logic clk,
    input  logic rst,                 // active-low cold reset
    output logic done,
    Membus.master bus
);
    logic [63:0] img [0:WORDS-1];
    int unsigned todo [$];
    bit verify;

    initial begin
        string path;
        int fd;
        path = FILEPATH_IS_ENV ? util::get_env(FILEPATH) : FILEPATH;
        if (path == "") $fatal(1, "SDRAM_PRELOAD: no RAM image (%0s is unset or empty)", FILEPATH);
        fd = $fopen(path, "r");
        if (fd == 0) $fatal(1, "SDRAM_PRELOAD: cannot open RAM image %0s", path);
        $fclose(fd);
        for (int unsigned i = 0; i < WORDS; i++) img[i] = '0;
        $readmemh(path, img);
        for (int unsigned i = 0; i < WORDS; i++) if (img[i] != 0) todo.push_back(i);
        verify = $test$plusargs("SDRAM_PRELOAD_VERIFY");
        $display("SDRAM_PRELOAD file=%0s nonzero_words=%0d verify=%0b", path, todo.size(), verify);
    end

    typedef enum logic [1:0] {P_REQ, P_WAIT, P_DONE} pstate_t;
    pstate_t st;
    bit reading;           // second pass (verify)
    int unsigned pos;
    longint unsigned cycles;

    // single cold start: the first reset release starts the preload; any later
    // reset is a reload, which this profile does not support.
    // A start is counted only on a release that follows a real assertion: a
    // falling edge of rst, or a clock edge sampled with rst low (rst may start
    // low). The CPU testbench drives rst high at time 0 before any clock edge;
    // that initial rise does not count. (No delays: the CPU sim has no --timing.)
    bit seen_assert = 0, started = 0;
    always @(negedge rst) begin
        if (started) $fatal(1, "SDRAM_PRELOAD: reset after start (reload) is not supported in this simulation profile");
        seen_assert = 1;
    end
    always @(posedge clk) if (!rst) seen_assert = 1;
    always @(posedge rst) if (seen_assert) started = 1;

    // Nothing happens before `started`: no request, no progress, no done.
    always_comb begin
        bus.valid = started && rst && (st == P_REQ) && (pos < todo.size());
        bus.addr  = (st == P_REQ && pos < todo.size()) ? 64'(todo[pos]) << 3 : '0;
        bus.wen   = !reading;
        bus.wdata = (pos < todo.size()) ? img[todo[pos]] : '0;
        bus.wmask = reading ? 8'h00 : 8'hff;
    end
    assign done = started && (st == P_DONE);

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            st <= P_REQ; pos <= 0; reading <= 0; cycles <= 0;
        end else if (started) begin
            cycles <= cycles + 1;
            unique case (st)
                P_REQ: begin
                    if (pos >= todo.size()) begin
                        if (verify && !reading) begin reading <= 1; pos <= 0; end
                        else begin
                            st <= P_DONE;
                            $display("SDRAM_PRELOAD done words=%0d verified=%0b cycles=%0d", todo.size(), reading, cycles);
                        end
                    end else if (bus.ready) st <= P_WAIT;
                end
                P_WAIT: if (bus.rvalid) begin
                    if (reading && bus.rdata !== img[todo[pos]])
                        $fatal(1, "SDRAM_PRELOAD verify mismatch at offset %h: %h != %h", 64'(todo[pos]) << 3, bus.rdata, img[todo[pos]]);
                    pos <= pos + 1; st <= P_REQ;
                end
                P_DONE: ;
                default: st <= P_REQ;
            endcase
        end
    end
endmodule
