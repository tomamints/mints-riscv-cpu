import eei::*;

module tb_address_translation;
	logic clk;
	logic rst;
	logic flush;
	logic req_valid;
	logic req_ready;
	Addr req_va;
	PrivMode req_priv_mode;
	PmpAccessType req_access_type;
	logic req_sum;
	logic req_mxr;
	UIntX satp;
	logic rsp_valid;
	logic rsp_ready;
	Addr rsp_pa;
	logic rsp_fault;
	Sv39Fault rsp_fault_detail;
	CsrCause rsp_fault_cause;
	Addr rsp_fault_value;
	logic ptw_mem_valid;
	Addr ptw_mem_addr;
	logic ptw_mem_ready;
	logic ptw_mem_rvalid;
	logic ptw_mem_error;
	logic [MEMBUS_DATA_WIDTH-1:0] ptw_mem_rdata;
	int unsigned ptw_request_count;

	localparam UIntX ROOT_PPN = UIntX'(44'h100);
	localparam UIntX SATP_SV39 = (UIntX'(8) << 60) | ROOT_PPN;

	function automatic logic [63:0] pte_for_addr(input Addr addr);
		unique case (addr)
			64'h0000_0000_0010_0000: return 64'h0000_0000_0004_0401; // L2 non-leaf -> PPN 0x101
			64'h0000_0000_0010_1000: return 64'h0000_0000_0004_0801; // L1 non-leaf -> PPN 0x102
			64'h0000_0000_0010_2020: return 64'h0000_0000_0000_104b; // L0 leaf, PPN 0x4, V/R/X/A
			default:                  return 64'h0;
		endcase
	endfunction

	address_translation dut (
		.clk(clk),
		.rst(rst),
		.flush(flush),
		.tlb_flush(flush),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.req_va(req_va),
		.req_priv_mode(req_priv_mode),
		.req_access_type(req_access_type),
		.req_sum(req_sum),
		.req_mxr(req_mxr),
		.satp(satp),
		.rsp_valid(rsp_valid),
		.rsp_ready(rsp_ready),
		.rsp_pa(rsp_pa),
		.rsp_fault(rsp_fault),
		.rsp_fault_detail(rsp_fault_detail),
		.rsp_fault_cause(rsp_fault_cause),
		.rsp_fault_value(rsp_fault_value),
		.ptw_mem_valid(ptw_mem_valid),
		.ptw_mem_addr(ptw_mem_addr),
		.ptw_mem_ready(ptw_mem_ready),
		.ptw_mem_rvalid(ptw_mem_rvalid),
		.ptw_mem_error(ptw_mem_error),
		.ptw_mem_rdata(ptw_mem_rdata)
	);

	always #1 clk = !clk;

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			ptw_mem_rvalid <= 1'b0;
			ptw_mem_error <= 1'b0;
			ptw_mem_rdata <= '0;
			ptw_request_count <= 0;
		end else begin
			ptw_mem_rvalid <= ptw_mem_valid;
			ptw_mem_error <= 1'b0;
			ptw_mem_rdata <= pte_for_addr(ptw_mem_addr);
			if (ptw_mem_valid && ptw_mem_ready) begin
				ptw_request_count <= ptw_request_count + 1;
			end
		end
	end

	task automatic check(input logic cond, input string msg);
		if (!cond) begin
			$fatal(1, "address_translation check failed: %s", msg);
		end
	endtask

	task automatic request_translation(
		input Addr va,
		input UIntX local_satp,
		input PrivMode priv,
		input PmpAccessType access
	);
		begin
			req_va = va;
			satp = local_satp;
			req_priv_mode = priv;
			req_access_type = access;
			while (!req_ready) begin
				@(posedge clk);
				#1;
			end
			req_valid = 1'b1;
			@(posedge clk);
			#1;
			req_valid = 1'b0;
		end
	endtask

	task automatic wait_response;
		begin
			while (!rsp_valid) begin
				@(posedge clk);
				#1;
			end
			@(posedge clk);
			#1;
		end
	endtask

	initial begin
		clk = 1'b0;
		rst = 1'b0;
		flush = 1'b0;
		req_valid = 1'b0;
		req_va = '0;
		req_priv_mode = S;
		req_access_type = PMP_ACCESS_EXEC;
		req_sum = 1'b0;
		req_mxr = 1'b0;
		satp = '0;
		rsp_ready = 1'b1;
		ptw_mem_ready = 1'b1;

		repeat (2) @(posedge clk);
		rst = 1'b1;
		@(posedge clk);
		#1;

		request_translation(64'h0000_0000_8000_1234, UIntX'(0), S, PMP_ACCESS_EXEC);
		wait_response();
		check(!rsp_fault, "bare translation must not fault");
		check(rsp_pa == 64'h0000_0000_8000_1234, "bare translation must return VA as PA");
		check(ptw_request_count == 0, "bare translation must not start PTW");

		request_translation(64'h0000_0000_0000_4568, SATP_SV39, S, PMP_ACCESS_EXEC);
		wait_response();
		check(!rsp_fault, "Sv39 L2 leaf translation must not fault");
		check(rsp_pa == 64'h0000_0000_0000_4568, "L2 identity leaf must return expected PA");
		check(ptw_request_count == 3, "first Sv39 request must miss and walk three levels");

		request_translation(64'h0000_0000_0000_4568, SATP_SV39, S, PMP_ACCESS_EXEC);
		wait_response();
		check(!rsp_fault, "refilled TLB request must not fault");
		check(rsp_pa == 64'h0000_0000_0000_4568, "refilled TLB request must return same PA");
		check(ptw_request_count == 3, "second same Sv39 request must hit TLB");

		flush = 1'b1;
		@(posedge clk);
		#1;
		flush = 1'b0;
		request_translation(64'h0000_0000_0000_4568, SATP_SV39, S, PMP_ACCESS_EXEC);
		wait_response();
		check(ptw_request_count == 6, "flush must force a new PTW walk");

		$display("[ADDRESS TRANSLATION TEST] pass");
		$finish;
	end
endmodule : tb_address_translation
