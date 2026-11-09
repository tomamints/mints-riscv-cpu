`timescale 1ns/1ps
module tb_de0_cv_blink;
    logic clk;
    logic reset_n;
    wire led, led_fast, led_one;
    int unsigned elapsed;
    de0_cv_blink dut (.CLOCK_50(clk), .KEY0_N(reset_n), .LEDR0(led));
    de0_cv_blink #(.HALF_PERIOD_CYCLES(3)) fast (
        .CLOCK_50(clk), .KEY0_N(reset_n), .LEDR0(led_fast));
    de0_cv_blink #(.HALF_PERIOD_CYCLES(1)) one (
        .CLOCK_50(clk), .KEY0_N(reset_n), .LEDR0(led_one));
    initial begin
        clk = 0;
        forever #10 clk = !clk;
    end

    task automatic check(input bit expected, input bit fast_expected, input bit one_expected);
        if ({led, led_fast, led_one} !== {expected, fast_expected, one_expected})
            $fatal(1, "LED mismatch t=%0t elapsed=%0d actual=%b%b%b expected=%b%b%b",
                $time, elapsed, led, led_fast, led_one, expected, fast_expected, one_expected);
    endtask

    task automatic apply_reset;
        // Reset off the clock edge, including while the LED is on.
        @(negedge clk); #3; reset_n = 0; #1;
        elapsed = 0;
        check(0, 0, 0);
        repeat (3) begin @(posedge clk); #1; check(0, 0, 0); end
        @(negedge clk); #3; reset_n = 1;
        // Two release synchronizer edges; counting begins on the third edge.
        repeat (2) begin @(posedge clk); #1; check(0, 0, 0); end
    endtask

    task automatic run_cycles(input int unsigned cycles);
        repeat (cycles) begin
            @(posedge clk); #1; elapsed++;
            check(1'((elapsed / 25_000_000) % 2),
                  1'((elapsed / 3) % 2), 1'(elapsed % 2));
        end
    endtask

    initial begin
        reset_n = 1;
        elapsed = 0;
        apply_reset();
        run_cycles(25_000_005); // first 0.5s edge and reset while the LED is on
        apply_reset();
        run_cycles(50_000_005); // complete 1s period at the actual default divider
        $display("BLINK-TEST-PASS: default 50MHz period, reset, dividers 1 and 3");
        $finish;
    end
    initial begin
        #1_600_000_000;
        $fatal(1, "Blink test timed out");
    end
endmodule
