`timescale 1ns/1ps
// Fault harness for rtl/bus/membus_sdram_adapter.sv with a scripted bridge.
// Run with +MEMBUS_SDRAM_FAULT_NONFATAL.
//   K2w/K2r: accepted write/read answered with rsp_error -> kind 2, no upstream
//            response, snapshot = that request (offset/abs/wen), blocked until
//            soft_reset;
//   K3:      unsolicited rsp_valid while idle -> kind 3;
//   K3c:     unsolicited rsp_valid in the same cycle as a pending upstream
//            request with the bridge ready -> no acceptance, no bridge request
//            in that cycle, kind 3, snapshot = last accepted request.
module tb_membus_sdram_adapter_faults;
    logic clk = 0; always #5 clk = ~clk;
    logic rst_n = 0, soft_reset = 0;
    Membus up_bus();
    logic req_valid, req_write, fault, fault_seen, fault_wen;
    logic [63:0] req_addr, req_wdata, fault_offset, fault_abs;
    logic [7:0] req_be; logic [1:0] fault_kind;
    // scripted bridge
    logic f_ready = 0, f_rsp_valid = 0, f_rsp_error = 0; logic [63:0] f_rsp_data = '0;
    membus_sdram_adapter dut(.clk(clk), .rst_n(rst_n), .soft_reset(soft_reset), .up(up_bus),
        .req_valid(req_valid), .req_ready(f_ready), .req_addr(req_addr), .req_write(req_write),
        .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(f_rsp_valid), .rsp_data(f_rsp_data),
        .rsp_error(f_rsp_error), .fault(fault), .fault_seen(fault_seen), .fault_kind(fault_kind),
        .fault_offset(fault_offset), .fault_abs(fault_abs), .fault_wen(fault_wen));
    logic m_valid = 0, m_wen = 0; logic [63:0] m_addr = 0, m_wdata = 0; logic [7:0] m_wmask = 0;
    assign up_bus.valid = m_valid; assign up_bus.addr = m_addr; assign up_bus.wen = m_wen;
    assign up_bus.wdata = m_wdata; assign up_bus.wmask = m_wmask;

    int unsigned up_rsp = 0;
    always @(posedge clk) if (up_bus.rvalid) up_rsp++;

    task automatic expect_snapshot(input logic [1:0] k, input logic [63:0] off, input bit w, input string name);
        if (!fault || !fault_seen || fault_kind !== k || fault_offset !== off || fault_wen !== w ||
            fault_abs !== 64'h8000_0000 + (off & ~64'h7))
            $fatal(1, "[%s] snapshot fault=%b seen=%b kind=%0d off=%h abs=%h wen=%b", name, fault, fault_seen, fault_kind, fault_offset, fault_abs, fault_wen);
        repeat (50) begin
            @(posedge clk); #1;
            if (up_bus.ready || up_bus.rvalid || req_valid) $fatal(1, "[%s] activity while faulted", name);
        end
    endtask
    task automatic clear_fault();
        @(negedge clk); #2 soft_reset = 1; @(posedge clk); @(negedge clk); #2 soft_reset = 0;
        @(posedge clk); #1;
        if (fault || !fault_seen) $fatal(1, "[CLEAR] fault=%b seen=%b", fault, fault_seen);
    endtask
    task automatic accept(input logic [63:0] off, input bit w);
        @(negedge clk); m_valid = 1; m_addr = off; m_wen = w; m_wdata = 64'h1234; m_wmask = 8'h0f; f_ready = 1;
        #1;
        if (!up_bus.ready || !req_valid) $fatal(1, "[ACCEPT] in-range request not presented (ready=%b req_valid=%b)", up_bus.ready, req_valid);
        @(posedge clk); #1;           // handshake at this edge; adapter now busy
        if (up_bus.ready || req_valid) $fatal(1, "[ACCEPT] still ready/requesting while busy");
        @(negedge clk); m_valid = 0; f_ready = 0;
    endtask
    task automatic bridge_error_case(input logic [63:0] off, input bit w, input string name);
        int n_before;
        n_before = up_rsp;
        accept(off, w);
        repeat (3) @(posedge clk);
        @(negedge clk); f_rsp_valid = 1; f_rsp_error = 1;
        @(posedge clk); #1;
        @(negedge clk); f_rsp_valid = 0; f_rsp_error = 0;
        if (up_rsp != n_before) $fatal(1, "[%s] bridge error produced an upstream response", name);
        expect_snapshot(2'd2, off, w, name);
        clear_fault();
    endtask

    initial begin
        repeat (3) @(posedge clk); @(negedge clk); #2 rst_n = 1;
        bridge_error_case(64'h0000_1238, 1'b1, "K2w");
        bridge_error_case(64'h03ff_fffc, 1'b0, "K2r");
        // K3: unsolicited response while idle
        @(negedge clk); f_rsp_valid = 1; @(posedge clk); #1; @(negedge clk); f_rsp_valid = 0;
        expect_snapshot(2'd3, 64'h03ff_fffc, 1'b0, "K3");      // last accepted = K2r
        clear_fault();
        // K3c: unsolicited response in the same cycle as a pending upstream request
        @(negedge clk); m_valid = 1; m_addr = 64'h0000_0040; m_wen = 1; m_wdata = '1; m_wmask = 8'hff;
        f_ready = 1; f_rsp_valid = 1;
        #1;
        if (up_bus.ready || req_valid) $fatal(1, "[K3c] request accepted/forwarded with an unexpected response");
        @(posedge clk); #1;
        @(negedge clk); f_rsp_valid = 0; m_valid = 0; f_ready = 0;
        expect_snapshot(2'd3, 64'h03ff_fffc, 1'b0, "K3c");     // the pending request was not taken
        clear_fault();
        if (up_rsp != 0) $fatal(1, "[ACCOUNT] upstream responses %0d (expected 0)", up_rsp);
        $display("MEMBUS_SDRAM_ADAPTER_FAULTS_PASS cases=K2w,K2r,K3,K3c");
        $finish;
    end
    initial begin #1_000_000; $fatal(1, "[WATCHDOG]"); end
endmodule
