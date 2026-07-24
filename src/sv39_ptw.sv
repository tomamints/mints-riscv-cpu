import eei::*;

module sv39_ptw (
	input logic clk,
	input logic rst,
	input logic start,
	output logic ready,
	input Addr va,
	input PmpAccessType access_type,
	input PrivMode priv_mode,
	input UIntX satp,
	input logic sum,
	input logic mxr,
	output logic done,
	output logic fault,
	output Sv39Fault fault_detail,
	output Addr pa,
	output CsrCause fault_cause,
	output Addr fault_value,
	output logic mem_valid,
	output Addr mem_addr,
	input logic mem_ready,
	input logic mem_rvalid,
	input logic mem_error,
	input logic [MEMBUS_DATA_WIDTH-1:0] mem_rdata
);

	typedef enum logic [2:0] {
		Idle,
		Req,
		WaitResp,
		Check,
		Done
	} State;

	State state;
	Addr req_va;
	PmpAccessType req_access_type;
	PrivMode req_priv_mode;
	logic req_sum;
	logic req_mxr;
	logic [1:0] level;
	UIntX base_ppn;
	UIntX pte;
	logic result_fault;
	Sv39Fault result_fault_detail;
	Addr result_pa;
	CsrCause result_fault_cause;

	logic [8:0] vpn;
	Addr pte_addr;
	logic pte_v, pte_r, pte_w, pte_x, pte_u, pte_a, pte_d;
	logic pte_v_invalid;
	logic pte_w_no_r;
	logic pte_reserved_fault;
	logic pte_nonleaf;
	logic pte_invalid;
	logic pte_reserved_nonleaf;
	logic pte_access_perm_fault;
	logic pte_ad_fault;
	logic superpage_misaligned;
	logic va_canonical;

	assign ready = state == Idle;
	assign done = state == Done;
	assign fault = result_fault;
	assign fault_detail = result_fault_detail;
	assign pa = result_pa;
	assign fault_cause = result_fault_cause;
	assign fault_value = req_va;

	assign mem_valid = state == Req;
	assign mem_addr = pte_addr;

	assign va_canonical = is_sv39_canonical(va);

	always_comb begin
		unique case (level)
			2'd2: vpn = req_va[38:30];
			2'd1: vpn = req_va[29:21];
			2'd0: vpn = req_va[20:12];
			default: vpn = 9'd0;
		endcase
	end

	assign pte_addr = (base_ppn << 12) + (Addr'(vpn) << 3);

	assign pte_v = pte[0];
	assign pte_r = pte[1];
	assign pte_w = pte[2];
	assign pte_x = pte[3];
	assign pte_u = pte[4];
	assign pte_a = pte[6];
	assign pte_d = pte[7];
	assign pte_nonleaf = !(pte_r || pte_x);
	assign pte_v_invalid = !pte_v;
	assign pte_w_no_r = pte_w && !pte_r;
	assign pte_reserved_fault = pte[63:54] != 10'b0;
	assign pte_invalid = pte_v_invalid || pte_w_no_r || pte_reserved_fault;
	assign pte_reserved_nonleaf = pte_nonleaf && (pte_u || pte_a || pte_d);

	always_comb begin
		unique case (level)
			2'd2: superpage_misaligned = pte[27:10] != 18'b0;
			2'd1: superpage_misaligned = pte[18:10] != 9'b0;
			default: superpage_misaligned = 1'b0;
		endcase
	end

	always_comb begin
		pte_access_perm_fault = 1'b0;
		unique case (req_access_type)
			PMP_ACCESS_READ:  pte_access_perm_fault = !(pte_r || (req_mxr && pte_x));
			PMP_ACCESS_WRITE: pte_access_perm_fault = !pte_w;
			PMP_ACCESS_EXEC:  pte_access_perm_fault = !pte_x;
			default:          pte_access_perm_fault = 1'b1;
		endcase

		if (req_priv_mode == U) begin
			if (!pte_u) begin
				pte_access_perm_fault = 1'b1;
			end
		end else if (req_priv_mode == S) begin
			if (pte_u) begin
				if (req_access_type == PMP_ACCESS_EXEC) begin
					pte_access_perm_fault = 1'b1;
				end else if (!req_sum) begin
					pte_access_perm_fault = 1'b1;
				end
			end
		end
	end

	always_comb begin
		pte_ad_fault = !pte_a;
		if (req_access_type == PMP_ACCESS_WRITE && !pte_d) begin
			pte_ad_fault = 1'b1;
		end
	end

	function automatic Addr leaf_pa(input UIntX leaf_pte, input Addr leaf_va, input logic [1:0] leaf_level);
		unique case (leaf_level)
			2'd2: return {8'b0, leaf_pte[53:28], leaf_va[29:12], leaf_va[11:0]};
			2'd1: return {8'b0, leaf_pte[53:19], leaf_va[20:12], leaf_va[11:0]};
			default: return {8'b0, leaf_pte[53:10], leaf_va[11:0]};
		endcase
	endfunction

	function automatic CsrCause page_fault_cause(input PmpAccessType access);
		unique case (access)
			PMP_ACCESS_EXEC:  return INSTRUCTION_PAGE_FAULT;
			PMP_ACCESS_WRITE: return STORE_AMO_PAGE_FAULT;
			default:          return LOAD_PAGE_FAULT;
		endcase
	endfunction

	function automatic CsrCause access_fault_cause(input PmpAccessType access);
		unique case (access)
			PMP_ACCESS_EXEC:  return INSTRUCTION_ACCESS_FAULT;
			PMP_ACCESS_WRITE: return STORE_AMO_ACCESS_FAULT;
			default:          return LOAD_ACCESS_FAULT;
		endcase
	endfunction

	function automatic logic is_sv39_canonical(input Addr addr);
		return addr[63:39] == {25{addr[38]}};
	endfunction

	function automatic Sv39Fault invalid_fault_detail(
		input logic v_invalid,
		input logic w_no_r
	);
		if (v_invalid) begin
			return SV39_FAULT_PTE_INVALID;
		end else if (w_no_r) begin
			return SV39_FAULT_W_NO_R;
		end else begin
			return SV39_FAULT_RESERVED;
		end
	endfunction

	function automatic Sv39Fault access_perm_fault_detail(
		input PmpAccessType access,
		input PrivMode priv,
		input logic r,
		input logic w,
		input logic x,
		input logic u,
		input logic local_sum,
		input logic local_mxr
	);
		if (access == PMP_ACCESS_READ && !(r || (local_mxr && x))) begin
			return SV39_FAULT_LOAD_R;
		end else if (access == PMP_ACCESS_WRITE && !w) begin
			return SV39_FAULT_STORE_W;
		end else if (access == PMP_ACCESS_EXEC && !x) begin
			return SV39_FAULT_FETCH_X;
		end else if (priv == U && !u) begin
			return SV39_FAULT_PTE_U;
		end else if (priv == S && u && access == PMP_ACCESS_EXEC) begin
			return SV39_FAULT_PTE_U;
		end else if (priv == S && u && !local_sum) begin
			return SV39_FAULT_PTE_SUM;
		end else begin
			return SV39_FAULT_RESERVED;
		end
	endfunction

	function automatic Sv39Fault ad_fault_detail(
		input logic a,
		input logic d,
		input PmpAccessType access
	);
		if (!a) begin
			return SV39_FAULT_PTE_A;
		end else if (access == PMP_ACCESS_WRITE && !d) begin
			return SV39_FAULT_PTE_D;
		end else begin
			return SV39_FAULT_RESERVED;
		end
	endfunction

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Idle;
			req_va <= '0;
			req_access_type <= PMP_ACCESS_READ;
			req_priv_mode <= M;
			req_sum <= 1'b0;
			req_mxr <= 1'b0;
			level <= 2'd2;
			base_ppn <= '0;
			pte <= '0;
			result_fault <= 1'b0;
			result_fault_detail <= SV39_FAULT_NONE;
			result_pa <= '0;
			result_fault_cause <= CsrCause'(0);
		end else begin
			case (state)
				Idle: begin
					if (start) begin
						req_va <= va;
						req_access_type <= access_type;
						req_priv_mode <= priv_mode;
						req_sum <= sum;
						req_mxr <= mxr;
						level <= 2'd2;
						base_ppn <= UIntX'(satp[43:0]);
						result_fault <= !va_canonical;
						result_fault_detail <= va_canonical ? SV39_FAULT_NONE : SV39_FAULT_ADDR_INVALID;
						result_pa <= '0;
						result_fault_cause <= page_fault_cause(access_type);
						state <= va_canonical ? Req : Done;
					end
				end

				Req: begin
					if (mem_ready) begin
						if ($test$plusargs("TRACE_SV39")) begin
							$display("[SV39] REQ level=%0d va=%h pte_addr=%h base_ppn=%h vpn=%h",
								level, req_va, pte_addr, base_ppn, vpn);
						end
						state <= WaitResp;
					end
				end

				WaitResp: begin
					if (mem_rvalid) begin
						if ($test$plusargs("TRACE_SV39")) begin
							$display("[SV39] RESP pte=%h", mem_rdata);
						end
						if (mem_error) begin
							result_fault <= 1'b1;
							result_fault_detail <= SV39_FAULT_PTE_MEM_ERROR;
							result_fault_cause <= access_fault_cause(req_access_type);
							state <= Done;
						end else begin
							pte <= UIntX'(mem_rdata[63:0]);
							state <= Check;
						end
					end
				end

				Check: begin
					if ($test$plusargs("TRACE_SV39")) begin
						$display("[SV39] CHECK level=%0d pte=%h invalid=%b reserved_nonleaf=%b nonleaf=%b access_perm_fault=%b superpage_misaligned=%b ad_fault=%b",
							level, pte, pte_invalid, pte_reserved_nonleaf, pte_nonleaf, pte_access_perm_fault, superpage_misaligned, pte_ad_fault);
					end
					if (pte_invalid) begin
						result_fault <= 1'b1;
						result_fault_detail <= invalid_fault_detail(pte_v_invalid, pte_w_no_r);
						state <= Done;
					end else if (pte_reserved_nonleaf) begin
						result_fault <= 1'b1;
						result_fault_detail <= SV39_FAULT_RESERVED;
						state <= Done;
					end else if (pte_nonleaf) begin
						if (level == 2'd0) begin
							result_fault <= 1'b1;
							result_fault_detail <= SV39_FAULT_NONLEAF_AT_L0;
							state <= Done;
						end else begin
							base_ppn <= UIntX'(pte[53:10]);
							level <= level - 2'd1;
							state <= Req;
						end
					end else if (pte_access_perm_fault) begin
						result_fault <= 1'b1;
						result_fault_detail <= access_perm_fault_detail(req_access_type, req_priv_mode, pte_r, pte_w, pte_x, pte_u, req_sum, req_mxr);
						state <= Done;
					end else if (superpage_misaligned) begin
						result_fault <= 1'b1;
						result_fault_detail <= SV39_FAULT_SUPERPAGE;
						state <= Done;
					end else if (pte_ad_fault) begin
						result_fault <= 1'b1;
						result_fault_detail <= ad_fault_detail(pte_a, pte_d, req_access_type);
						state <= Done;
					end else begin
						result_fault <= 1'b0;
						result_fault_detail <= SV39_FAULT_NONE;
						result_pa <= leaf_pa(pte, req_va, level);
						state <= Done;
					end
				end

				Done: begin
					state <= Idle;
				end

				default: state <= Idle;
			endcase
		end
	end
endmodule : sv39_ptw
