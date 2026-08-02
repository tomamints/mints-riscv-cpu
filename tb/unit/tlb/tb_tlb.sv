import eei::*;

module tb_tlb;
	logic clk;
	logic rst;
	logic flush;
	logic lookup_valid;
	Addr lookup_va;
	PrivMode lookup_priv_mode;
	PmpAccessType lookup_access_type;
	logic lookup_sum;
	logic lookup_mxr;
	logic hit;
	Addr pa;
	logic fault;
	Sv39Fault fault_detail;
	logic refill_valid;
	Addr refill_va;
	logic [43:0] refill_ppn;
	logic [1:0] refill_level;
	logic refill_r;
	logic refill_w;
	logic refill_x;
	logic refill_u;
	logic refill_g;
	logic refill_a;
	logic refill_d;

	tlb #(
		.ENTRY_COUNT(8)
	) dut (
		.clk(clk),
		.rst(rst),
		.flush(flush),
		.lookup_valid(lookup_valid),
		.lookup_va(lookup_va),
		.lookup_priv_mode(lookup_priv_mode),
		.lookup_access_type(lookup_access_type),
		.lookup_sum(lookup_sum),
		.lookup_mxr(lookup_mxr),
		.hit(hit),
		.pa(pa),
		.fault(fault),
		.fault_detail(fault_detail),
		.refill_valid(refill_valid),
		.refill_va(refill_va),
		.refill_ppn(refill_ppn),
		.refill_level(refill_level),
		.refill_r(refill_r),
		.refill_w(refill_w),
		.refill_x(refill_x),
		.refill_u(refill_u),
		.refill_g(refill_g),
		.refill_a(refill_a),
		.refill_d(refill_d)
	);

	always #1 clk = !clk;

	task automatic check(input logic cond, input string msg);
		if (!cond) begin
			$fatal(1, "TLB check failed: %s", msg);
		end
	endtask

	task automatic refill(
		input Addr va,
		input logic [43:0] ppn,
		input logic [1:0] level,
		input logic r,
		input logic w,
		input logic x,
		input logic u,
		input logic a,
		input logic d
	);
		begin
			refill_va = va;
			refill_ppn = ppn;
			refill_level = level;
			refill_r = r;
			refill_w = w;
			refill_x = x;
			refill_u = u;
			refill_g = 1'b0;
			refill_a = a;
			refill_d = d;
			refill_valid = 1'b1;
			@(posedge clk);
			#1;
			refill_valid = 1'b0;
		end
	endtask

	task automatic lookup(
		input Addr va,
		input PrivMode priv,
		input PmpAccessType access,
		input logic sum,
		input logic mxr
	);
		begin
			lookup_va = va;
			lookup_priv_mode = priv;
			lookup_access_type = access;
			lookup_sum = sum;
			lookup_mxr = mxr;
			lookup_valid = 1'b1;
			#1;
		end
	endtask

	initial begin
		clk = 1'b0;
		rst = 1'b0;
		flush = 1'b0;
		lookup_valid = 1'b0;
		lookup_va = '0;
		lookup_priv_mode = S;
		lookup_access_type = PMP_ACCESS_EXEC;
		lookup_sum = 1'b0;
		lookup_mxr = 1'b0;
		refill_valid = 1'b0;
		refill_va = '0;
		refill_ppn = '0;
		refill_level = 2'd0;
		refill_r = 1'b0;
		refill_w = 1'b0;
		refill_x = 1'b0;
		refill_u = 1'b0;
		refill_g = 1'b0;
		refill_a = 1'b0;
		refill_d = 1'b0;

		repeat (2) @(posedge clk);
		rst = 1'b1;
		@(posedge clk);
		#1;

		lookup(64'h0000_0000_0000_1234, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(!hit, "empty TLB must miss");

		refill(64'h0000_0000_0000_1000, 44'h0000_0000_0123, 2'd0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
		lookup(64'h0000_0000_0000_1456, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit, "refilled VPN must hit");
		check(!fault, "S-mode execute on supervisor executable page must pass");
		check(pa == 64'h0000_0000_0012_3456, "4KiB PA must use refill PPN and VA offset");

		refill(64'h0000_0000_0000_2000, 44'h0000_0000_0456, 2'd0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
		lookup(64'h0000_0000_0000_2000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit && fault && fault_detail == SV39_FAULT_FETCH_X, "X=0 must fault instruction fetch");

		refill(64'h0000_0000_0000_3000, 44'h0000_0000_0789, 2'd0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0);
		lookup(64'h0000_0000_0000_3000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit && fault && fault_detail == SV39_FAULT_PTE_U, "S-mode must not execute U page");
		lookup(64'h0000_0000_0000_3000, U, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit && !fault, "U-mode may execute U executable page");

		refill(64'h0000_0000_0000_4000, 44'h0000_0000_0999, 2'd0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);
		lookup(64'h0000_0000_0000_4000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit && fault && fault_detail == SV39_FAULT_PTE_A, "A=0 must fault");

		flush = 1'b1;
		@(posedge clk);
		#1;
		flush = 1'b0;
		lookup(64'h0000_0000_0000_1000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(!hit, "flush must invalidate entries");

		refill(64'hffff_ffff_8020_0000, 44'h0000_0000_0802, 2'd1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
		lookup(64'hffff_ffff_8021_2340, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit, "2MiB superpage refill must hit within the same VPN[2:1]");
		check(pa == 64'h0000_0000_8021_2340, "2MiB PA must combine PPN[2:1] with VA[20:0]");

		refill(64'hffff_ffff_8000_0000, 44'h0000_0000_0800, 2'd2, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
		lookup(64'hffff_ffff_8123_4560, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit, "1GiB superpage refill must hit within the same VPN[2]");
		check(pa == 64'h0000_0000_8123_4560, "1GiB PA must combine PPN[2] with VA[29:0]");

		for (int unsigned i = 0; i < 8; i++) begin
			refill(64'h0000_0000_0001_0000 + (Addr'(i) << 12), 44'(44'h1000 + i), 2'd0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
		end
		lookup(64'h0000_0000_0001_0000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(hit, "first entry should still hit before wrap refill");
		refill(64'h0000_0000_0002_0000, 44'h0000_0000_2000, 2'd0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0);
		lookup(64'h0000_0000_0001_0000, S, PMP_ACCESS_EXEC, 1'b0, 1'b0);
		check(!hit, "round-robin refill must evict first entry after wrap");

		$display("[TLB TEST] pass");
		$finish;
	end
endmodule : tb_tlb
