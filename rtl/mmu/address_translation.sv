import eei::*;

module address_translation #(
	parameter string PERF_NAME = "TRANSLATION"
) (
	input logic clk,
	input logic rst,
	input logic flush,
	input logic tlb_flush,

	input logic req_valid,
	output logic req_ready,
	input Addr req_va,
	input PrivMode req_priv_mode,
	input PmpAccessType req_access_type,
	input logic req_sum,
	input logic req_mxr,
	input UIntX satp,
	input UIntX pmpcfg0,
	input UIntX pmpaddr0,
	input UIntX pmpaddr1,
	input UIntX pmpaddr2,
	input UIntX pmpaddr3,
	input UIntX pmpaddr4,
	input UIntX pmpaddr5,
	input UIntX pmpaddr6,
	input UIntX pmpaddr7,

	output logic rsp_valid,
	input logic rsp_ready,
	output Addr rsp_pa,
	output logic rsp_fault,
	output Sv39Fault rsp_fault_detail,
	output CsrCause rsp_fault_cause,
	output Addr rsp_fault_value,

	output logic ptw_mem_valid,
	output Addr ptw_mem_addr,
	input logic ptw_mem_ready,
	input logic ptw_mem_rvalid,
	input logic ptw_mem_error,
	input logic [MEMBUS_DATA_WIDTH-1:0] ptw_mem_rdata
);

	typedef enum logic [1:0] {
		Idle,
		PtwWait,
		Refill,
		Response
	} State;

	State state;

	Addr pending_va;
	PrivMode pending_priv_mode;
	PmpAccessType pending_access_type;
	logic pending_sum;
	logic pending_mxr;
	UIntX pending_satp;
	logic ptw_started;

	Addr result_pa;
	logic result_fault;
	Sv39Fault result_fault_detail;
	CsrCause result_fault_cause;
	Addr result_fault_value;
	Addr refill_pa;
	UIntX refill_leaf_pte;
	logic [1:0] refill_leaf_level;
	logic refill_leaf_valid;

	logic tlb_hit;
	Addr tlb_pa;
	logic tlb_fault;
	Sv39Fault tlb_fault_detail;
	logic tlb_lookup_valid;
	logic tlb_refill_valid;
	logic req_needs_ptw;
	logic fast_rsp_valid;
	Addr fast_rsp_pa;
	logic fast_rsp_fault;
	Sv39Fault fast_rsp_fault_detail;
	CsrCause fast_rsp_fault_cause;
	Addr fast_rsp_fault_value;
	logic fast_rsp_is_bare;
	logic fast_rsp_is_unsupported;
	logic fast_rsp_is_tlb_hit;

	logic ptw_start;
	logic ptw_ready;
	logic ptw_done;
	logic ptw_fault;
	Sv39Fault ptw_fault_detail;
	Addr ptw_pa;
	CsrCause ptw_fault_cause;
	Addr ptw_fault_value;
	logic ptw_leaf_valid;
	UIntX ptw_leaf_pte;
	logic [1:0] ptw_leaf_level;
	logic ptw_mem_valid_raw;
	logic ptw_mem_pmp_allow;
	logic ptw_mem_ready_to_ptw;
	logic ptw_mem_rvalid_to_ptw;
	logic ptw_mem_error_to_ptw;
	logic [MEMBUS_DATA_WIDTH-1:0] ptw_mem_rdata_to_ptw;
	logic ptw_pmp_fault_pending;
	logic ptw_pmp_deny_fire;
	logic ptw_perf_state_req;
	logic ptw_perf_state_wait_resp;
	logic ptw_perf_state_check;
	logic ptw_perf_state_done;
	UInt64 perf_req_count;
	UInt64 perf_bare_count;
	UInt64 perf_unsupported_mode_count;
	UInt64 perf_lookup_count;
	UInt64 perf_hit_count;
	UInt64 perf_hit_fault_count;
	UInt64 perf_miss_count;
	UInt64 perf_miss_cycle_count;
	UInt64 perf_ptw_start_count;
	UInt64 perf_ptw_done_count;
	UInt64 perf_ptw_fault_count;
	UInt64 perf_ptw_mem_req_count;
	UInt64 perf_ptw_mem_resp_count;
	UInt64 perf_leaf_l0_count;
	UInt64 perf_leaf_l1_count;
	UInt64 perf_leaf_l2_count;
	UInt64 perf_refill_count;
	UInt64 perf_superpage_refill_count;
	UInt64 perf_flush_count;
	UInt64 perf_ptw_req_wait_cycle;
	UInt64 perf_ptw_rsp_wait_cycle;
	UInt64 perf_ptw_check_cycle;
	UInt64 perf_ptw_pmp_deny_count;
	UInt64 perf_ptw_pmp_deny_cycle;
	UInt64 perf_ptw_other_cycle;
	UInt64 perf_fast_bare_count;
	UInt64 perf_fast_unsupported_count;
	UInt64 perf_fast_hit_count;
	UInt64 perf_fast_hit_fault_count;
	UInt64 perf_held_response_count;

	assign req_needs_ptw = satp[63:60] == 4'd8 && req_priv_mode != M;
	assign req_ready = state == Idle && (!req_needs_ptw || ptw_ready);
	assign fast_rsp_is_bare = satp[63:60] == 4'd0 || req_priv_mode == M;
	assign fast_rsp_is_unsupported = satp[63:60] != 4'd8 && !fast_rsp_is_bare;
	assign fast_rsp_is_tlb_hit = req_needs_ptw && tlb_hit;
	assign fast_rsp_valid =
		state == Idle &&
		req_valid &&
		req_ready &&
		(fast_rsp_is_bare || fast_rsp_is_unsupported || fast_rsp_is_tlb_hit);
	assign fast_rsp_pa =
		fast_rsp_is_bare ? req_va :
		fast_rsp_is_tlb_hit ? tlb_pa :
		'0;
	assign fast_rsp_fault = fast_rsp_is_unsupported || (fast_rsp_is_tlb_hit && tlb_fault);
	assign fast_rsp_fault_detail =
		fast_rsp_is_unsupported ? SV39_FAULT_ADDR_INVALID :
		(fast_rsp_is_tlb_hit && tlb_fault) ? tlb_fault_detail :
		SV39_FAULT_NONE;
	assign fast_rsp_fault_cause =
		fast_rsp_fault ? page_fault_cause(req_access_type) : CsrCause'(0);
	assign fast_rsp_fault_value = req_va;
	assign rsp_valid = fast_rsp_valid || state == Response;
	assign rsp_pa = fast_rsp_valid ? fast_rsp_pa : result_pa;
	assign rsp_fault = fast_rsp_valid ? fast_rsp_fault : result_fault;
	assign rsp_fault_detail = fast_rsp_valid ? fast_rsp_fault_detail : result_fault_detail;
	assign rsp_fault_cause = fast_rsp_valid ? fast_rsp_fault_cause : result_fault_cause;
	assign rsp_fault_value = fast_rsp_valid ? fast_rsp_fault_value : result_fault_value;

	assign ptw_start = state == PtwWait && !ptw_started && ptw_ready;
	assign tlb_lookup_valid = state == Idle && req_ready && req_valid && req_needs_ptw;
	assign tlb_refill_valid = state == Refill && refill_leaf_valid;
	assign ptw_mem_valid = ptw_mem_valid_raw && ptw_mem_pmp_allow;
	assign ptw_mem_ready_to_ptw = ptw_mem_pmp_allow ? ptw_mem_ready : !flush;
	assign ptw_mem_rvalid_to_ptw = ptw_mem_rvalid || ptw_pmp_fault_pending;
	assign ptw_mem_error_to_ptw = ptw_mem_error || ptw_pmp_fault_pending;
	assign ptw_mem_rdata_to_ptw = ptw_pmp_fault_pending ? '0 : ptw_mem_rdata;
	assign ptw_pmp_deny_fire = ptw_mem_valid_raw && !ptw_mem_pmp_allow && ptw_mem_ready_to_ptw;

	function automatic CsrCause page_fault_cause(input PmpAccessType access_type);
		unique case (access_type)
			PMP_ACCESS_EXEC:  return INSTRUCTION_PAGE_FAULT;
			PMP_ACCESS_WRITE: return STORE_AMO_PAGE_FAULT;
			default:          return LOAD_PAGE_FAULT;
		endcase
	endfunction

	tlb #(
		.ENTRY_COUNT(8)
	) translation_tlb (
		.clk(clk),
		.rst(rst),
		.flush(tlb_flush),
		.lookup_valid(tlb_lookup_valid),
		.lookup_va(req_va),
		.lookup_priv_mode(req_priv_mode),
		.lookup_access_type(req_access_type),
		.lookup_sum(req_sum),
		.lookup_mxr(req_mxr),
		.hit(tlb_hit),
		.pa(tlb_pa),
		.fault(tlb_fault),
		.fault_detail(tlb_fault_detail),
		.refill_valid(tlb_refill_valid),
		.refill_va(pending_va),
		.refill_ppn(refill_leaf_pte[53:10]),
		.refill_level(refill_leaf_level),
		.refill_r(refill_leaf_pte[1]),
		.refill_w(refill_leaf_pte[2]),
		.refill_x(refill_leaf_pte[3]),
		.refill_u(refill_leaf_pte[4]),
		.refill_g(refill_leaf_pte[5]),
		.refill_a(refill_leaf_pte[6]),
		.refill_d(refill_leaf_pte[7])
	);

	pmp_checker ptw_pmp_checker (
		.priv_mode(S),
		.access_start(ptw_mem_addr),
		.access_size(UIntX'(8)),
		.access_type(PMP_ACCESS_READ),
		.pmpcfg0(pmpcfg0),
		.pmpaddr0(pmpaddr0),
		.pmpaddr1(pmpaddr1),
		.pmpaddr2(pmpaddr2),
		.pmpaddr3(pmpaddr3),
		.pmpaddr4(pmpaddr4),
		.pmpaddr5(pmpaddr5),
		.pmpaddr6(pmpaddr6),
		.pmpaddr7(pmpaddr7),
		.allow(ptw_mem_pmp_allow)
	);

	sv39_ptw ptw (
		.clk(clk),
		.rst(rst),
		.flush(flush),
		.start(ptw_start),
		.ready(ptw_ready),
		.va(pending_va),
		.access_type(pending_access_type),
		.priv_mode(pending_priv_mode),
		.satp(pending_satp),
		.sum(pending_sum),
		.mxr(pending_mxr),
		.done(ptw_done),
		.fault(ptw_fault),
		.fault_detail(ptw_fault_detail),
		.pa(ptw_pa),
		.fault_cause(ptw_fault_cause),
		.fault_value(ptw_fault_value),
		.leaf_valid(ptw_leaf_valid),
		.leaf_pte(ptw_leaf_pte),
		.leaf_level(ptw_leaf_level),
		.mem_valid(ptw_mem_valid_raw),
		.mem_addr(ptw_mem_addr),
		.mem_ready(ptw_mem_ready_to_ptw),
		.mem_rvalid(ptw_mem_rvalid_to_ptw),
		.mem_error(ptw_mem_error_to_ptw),
		.mem_rdata(ptw_mem_rdata_to_ptw),
		.perf_state_req(ptw_perf_state_req),
		.perf_state_wait_resp(ptw_perf_state_wait_resp),
		.perf_state_check(ptw_perf_state_check),
		.perf_state_done(ptw_perf_state_done)
	);

	always_ff @(posedge clk or negedge rst) begin
		if (!rst || flush) begin
			ptw_pmp_fault_pending <= 1'b0;
		end else begin
			ptw_pmp_fault_pending <= 1'b0;
			if (ptw_pmp_deny_fire) begin
				ptw_pmp_fault_pending <= 1'b1;
			end
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			perf_req_count <= '0;
			perf_bare_count <= '0;
			perf_unsupported_mode_count <= '0;
			perf_lookup_count <= '0;
			perf_hit_count <= '0;
			perf_hit_fault_count <= '0;
			perf_miss_count <= '0;
			perf_miss_cycle_count <= '0;
			perf_ptw_start_count <= '0;
			perf_ptw_done_count <= '0;
			perf_ptw_fault_count <= '0;
			perf_ptw_mem_req_count <= '0;
			perf_ptw_mem_resp_count <= '0;
			perf_leaf_l0_count <= '0;
			perf_leaf_l1_count <= '0;
			perf_leaf_l2_count <= '0;
			perf_refill_count <= '0;
			perf_superpage_refill_count <= '0;
			perf_flush_count <= '0;
			perf_ptw_req_wait_cycle <= '0;
			perf_ptw_rsp_wait_cycle <= '0;
			perf_ptw_check_cycle <= '0;
			perf_ptw_pmp_deny_count <= '0;
			perf_ptw_pmp_deny_cycle <= '0;
			perf_ptw_other_cycle <= '0;
			perf_fast_bare_count <= '0;
			perf_fast_unsupported_count <= '0;
			perf_fast_hit_count <= '0;
			perf_fast_hit_fault_count <= '0;
			perf_held_response_count <= '0;
		end else begin
			if (tlb_flush) begin
				perf_flush_count <= perf_flush_count + UInt64'(1);
			end

			if (state == Idle && req_valid && req_ready) begin
				perf_req_count <= perf_req_count + UInt64'(1);

				if (satp[63:60] == 4'd0 || req_priv_mode == M) begin
					perf_bare_count <= perf_bare_count + UInt64'(1);
				end else if (satp[63:60] != 4'd8) begin
					perf_unsupported_mode_count <= perf_unsupported_mode_count + UInt64'(1);
				end else begin
					perf_lookup_count <= perf_lookup_count + UInt64'(1);
					if (tlb_hit) begin
						perf_hit_count <= perf_hit_count + UInt64'(1);
						if (tlb_fault) begin
							perf_hit_fault_count <= perf_hit_fault_count + UInt64'(1);
						end
					end else begin
						perf_miss_count <= perf_miss_count + UInt64'(1);
					end
				end
			end
			if (fast_rsp_valid && rsp_ready) begin
				if (fast_rsp_is_bare) begin
					perf_fast_bare_count <= perf_fast_bare_count + UInt64'(1);
				end else if (fast_rsp_is_unsupported) begin
					perf_fast_unsupported_count <= perf_fast_unsupported_count + UInt64'(1);
				end else begin
					perf_fast_hit_count <= perf_fast_hit_count + UInt64'(1);
					if (fast_rsp_fault) begin
						perf_fast_hit_fault_count <= perf_fast_hit_fault_count + UInt64'(1);
					end
				end
			end else if (fast_rsp_valid) begin
				perf_held_response_count <= perf_held_response_count + UInt64'(1);
			end

			if (state == PtwWait) begin
				perf_miss_cycle_count <= perf_miss_cycle_count + UInt64'(1);
				if (ptw_perf_state_req && ptw_mem_valid_raw && ptw_mem_pmp_allow && !ptw_mem_ready) begin
					perf_ptw_req_wait_cycle <= perf_ptw_req_wait_cycle + UInt64'(1);
				end else if (ptw_perf_state_wait_resp) begin
					perf_ptw_rsp_wait_cycle <= perf_ptw_rsp_wait_cycle + UInt64'(1);
				end else if (ptw_perf_state_check) begin
					perf_ptw_check_cycle <= perf_ptw_check_cycle + UInt64'(1);
				end else if (ptw_perf_state_req && ptw_mem_valid_raw && !ptw_mem_pmp_allow) begin
					perf_ptw_pmp_deny_cycle <= perf_ptw_pmp_deny_cycle + UInt64'(1);
				end else if (!ptw_done) begin
					perf_ptw_other_cycle <= perf_ptw_other_cycle + UInt64'(1);
				end
			end
			if (ptw_start) begin
				perf_ptw_start_count <= perf_ptw_start_count + UInt64'(1);
			end
			if (ptw_done) begin
				perf_ptw_done_count <= perf_ptw_done_count + UInt64'(1);
				if (ptw_fault) begin
					perf_ptw_fault_count <= perf_ptw_fault_count + UInt64'(1);
				end else if (ptw_leaf_valid) begin
					unique case (ptw_leaf_level)
						2'd0: perf_leaf_l0_count <= perf_leaf_l0_count + UInt64'(1);
						2'd1: perf_leaf_l1_count <= perf_leaf_l1_count + UInt64'(1);
						2'd2: perf_leaf_l2_count <= perf_leaf_l2_count + UInt64'(1);
						default: begin end
					endcase
					if (ptw_leaf_level != 2'd0) begin
						perf_superpage_refill_count <= perf_superpage_refill_count + UInt64'(1);
					end
				end
			end
			if (ptw_mem_valid && ptw_mem_ready) begin
				perf_ptw_mem_req_count <= perf_ptw_mem_req_count + UInt64'(1);
			end
			if (ptw_pmp_deny_fire) begin
				perf_ptw_pmp_deny_count <= perf_ptw_pmp_deny_count + UInt64'(1);
			end
			if (state == PtwWait && ptw_mem_rvalid) begin
				perf_ptw_mem_resp_count <= perf_ptw_mem_resp_count + UInt64'(1);
			end
			if (tlb_refill_valid) begin
				perf_refill_count <= perf_refill_count + UInt64'(1);
			end
		end
	end

	final begin
		if ($test$plusargs("PERF_SUMMARY")) begin
			$display("[PERF-%s] req=%0d bare=%0d unsupported=%0d lookup=%0d hit=%0d miss=%0d hit_fault=%0d hit_rate_x1000=%0d",
				PERF_NAME,
				perf_req_count,
				perf_bare_count,
				perf_unsupported_mode_count,
				perf_lookup_count,
				perf_hit_count,
				perf_miss_count,
				perf_hit_fault_count,
				(perf_lookup_count == 0) ? UInt64'(0) : (perf_hit_count * UInt64'(1000)) / perf_lookup_count);
			$display("[PERF-%s] ptw start=%0d done=%0d fault=%0d miss_cycles=%0d mem_req=%0d mem_resp=%0d",
				PERF_NAME,
				perf_ptw_start_count,
				perf_ptw_done_count,
				perf_ptw_fault_count,
				perf_miss_cycle_count,
				perf_ptw_mem_req_count,
				perf_ptw_mem_resp_count);
			$display("[PERF-%s] ptw_wait req=%0d rsp=%0d check=%0d pmp_deny=%0d pmp_deny_cycles=%0d other=%0d",
				PERF_NAME,
				perf_ptw_req_wait_cycle,
				perf_ptw_rsp_wait_cycle,
				perf_ptw_check_cycle,
				perf_ptw_pmp_deny_count,
				perf_ptw_pmp_deny_cycle,
				perf_ptw_other_cycle);
			$display("[PERF-%s] leaf_l0_4k=%0d leaf_l1_2m=%0d leaf_l2_1g=%0d refill=%0d superpage_refill=%0d flush=%0d",
				PERF_NAME,
				perf_leaf_l0_count,
				perf_leaf_l1_count,
				perf_leaf_l2_count,
				perf_refill_count,
				perf_superpage_refill_count,
				perf_flush_count);
			$display("[PERF-%s-FAST] bare=%0d unsupported=%0d hit=%0d hit_fault=%0d held=%0d",
				PERF_NAME,
				perf_fast_bare_count,
				perf_fast_unsupported_count,
				perf_fast_hit_count,
				perf_fast_hit_fault_count,
				perf_held_response_count);
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst || flush) begin
			state <= Idle;
			pending_va <= '0;
			pending_priv_mode <= M;
			pending_access_type <= PMP_ACCESS_READ;
			pending_sum <= 1'b0;
			pending_mxr <= 1'b0;
			pending_satp <= '0;
			ptw_started <= 1'b0;
			result_pa <= '0;
			result_fault <= 1'b0;
			result_fault_detail <= SV39_FAULT_NONE;
			result_fault_cause <= CsrCause'(0);
			result_fault_value <= '0;
			refill_pa <= '0;
			refill_leaf_pte <= '0;
			refill_leaf_level <= 2'd0;
			refill_leaf_valid <= 1'b0;
		end else begin
			unique case (state)
				Idle: begin
					if (req_valid && req_ready) begin
						pending_va <= req_va;
						pending_priv_mode <= req_priv_mode;
						pending_access_type <= req_access_type;
						pending_sum <= req_sum;
						pending_mxr <= req_mxr;
						pending_satp <= satp;
						ptw_started <= 1'b0;
						result_fault_value <= req_va;
						refill_pa <= '0;
						refill_leaf_pte <= '0;
						refill_leaf_level <= 2'd0;
						refill_leaf_valid <= 1'b0;

						if (fast_rsp_valid) begin
							result_pa <= fast_rsp_pa;
							result_fault <= fast_rsp_fault;
							result_fault_detail <= fast_rsp_fault_detail;
							result_fault_cause <= fast_rsp_fault_cause;
							state <= rsp_ready ? Idle : Response;
						end else begin
							result_pa <= '0;
							result_fault <= 1'b0;
							result_fault_detail <= SV39_FAULT_NONE;
							result_fault_cause <= CsrCause'(0);
							state <= PtwWait;
						end
					end
				end

				PtwWait: begin
					if (ptw_start) begin
						ptw_started <= 1'b1;
					end

					if (ptw_done) begin
						result_pa <= ptw_pa;
						result_fault <= ptw_fault;
						result_fault_detail <= ptw_fault_detail;
						result_fault_cause <= ptw_fault_cause;
						result_fault_value <= ptw_fault_value;
						refill_pa <= ptw_pa;
						refill_leaf_pte <= ptw_leaf_pte;
						refill_leaf_level <= ptw_leaf_level;
						refill_leaf_valid <= ptw_leaf_valid && !ptw_fault;
						state <= ptw_fault ? Response : Refill;
					end else if (ptw_started && ptw_ready) begin
						ptw_started <= 1'b0;
					end
				end

				Refill: begin
					state <= Response;
				end

				Response: begin
					if (rsp_ready) begin
						state <= Idle;
					end
				end

				default: begin
					state <= Idle;
				end
			endcase
		end
	end
endmodule : address_translation
