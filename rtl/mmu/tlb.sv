import eei::*;

module tlb #(
	parameter int unsigned ENTRY_COUNT = 8,
	parameter int unsigned VPN_WIDTH = 27,
	parameter int unsigned PPN_WIDTH = 44
) (
	input logic clk,
	input logic rst,
	input logic flush,

	input logic lookup_valid,
	input Addr lookup_va,
	input PrivMode lookup_priv_mode,
	input PmpAccessType lookup_access_type,
	input logic lookup_sum,
	input logic lookup_mxr,

	output logic hit,
	output Addr pa,
	output logic fault,
	output Sv39Fault fault_detail,

	input logic refill_valid,
	input Addr refill_va,
	input logic [PPN_WIDTH-1:0] refill_ppn,
	input logic [1:0] refill_level,
	input logic refill_r,
	input logic refill_w,
	input logic refill_x,
	input logic refill_u,
	input logic refill_g,
	input logic refill_a,
	input logic refill_d
);

	localparam int unsigned INDEX_WIDTH = ENTRY_COUNT <= 1 ? 1 : $clog2(ENTRY_COUNT);

	typedef struct packed {
		logic valid;
		logic [VPN_WIDTH-1:0] vpn;
		logic [PPN_WIDTH-1:0] ppn;
		logic [1:0] level;
		logic global_bit;
		logic user;
		logic read;
		logic write;
		logic execute;
		logic accessed;
		logic dirty;
	} TlbEntry;

	TlbEntry entries [ENTRY_COUNT];
	logic [INDEX_WIDTH-1:0] replace_index;

	logic [VPN_WIDTH-1:0] lookup_vpn;
	logic [VPN_WIDTH-1:0] refill_vpn;
	TlbEntry matched_entry;
	logic refill_match;
	logic [INDEX_WIDTH-1:0] refill_index;

	assign lookup_vpn = lookup_va[38:12];
	assign refill_vpn = refill_va[38:12];

	function automatic logic vpn_matches(
		input logic [VPN_WIDTH-1:0] entry_vpn,
		input logic [1:0] entry_level,
		input logic [VPN_WIDTH-1:0] request_vpn
	);
		unique case (entry_level)
			2'd2: return entry_vpn[26:18] == request_vpn[26:18];
			2'd1: return entry_vpn[26:9] == request_vpn[26:9];
			default: return entry_vpn == request_vpn;
		endcase
	endfunction

	function automatic Addr translated_pa(
		input TlbEntry entry,
		input Addr va
	);
		unique case (entry.level)
			2'd2: return {8'b0, entry.ppn[43:18], va[29:0]};
			2'd1: return {8'b0, entry.ppn[43:9], va[20:0]};
			default: return {8'b0, entry.ppn, va[11:0]};
		endcase
	endfunction

	function automatic Sv39Fault permission_fault_detail(
		input TlbEntry entry,
		input PmpAccessType access_type,
		input PrivMode priv_mode,
		input logic sum,
		input logic mxr
	);
		if (access_type == PMP_ACCESS_READ && !(entry.read || (mxr && entry.execute))) begin
			return SV39_FAULT_LOAD_R;
		end else if (access_type == PMP_ACCESS_WRITE && !entry.write) begin
			return SV39_FAULT_STORE_W;
		end else if (access_type == PMP_ACCESS_EXEC && !entry.execute) begin
			return SV39_FAULT_FETCH_X;
		end else if (priv_mode == U && !entry.user) begin
			return SV39_FAULT_PTE_U;
		end else if (priv_mode == S && entry.user && access_type == PMP_ACCESS_EXEC) begin
			return SV39_FAULT_PTE_U;
		end else if (priv_mode == S && entry.user && !sum) begin
			return SV39_FAULT_PTE_SUM;
		end else if (!entry.accessed) begin
			return SV39_FAULT_PTE_A;
		end else if (access_type == PMP_ACCESS_WRITE && !entry.dirty) begin
			return SV39_FAULT_PTE_D;
		end else begin
			return SV39_FAULT_NONE;
		end
	endfunction

	function automatic logic entry_allows_access(
		input TlbEntry entry,
		input PmpAccessType access_type,
		input PrivMode priv_mode,
		input logic sum,
		input logic mxr
	);
		logic allowed;

		allowed = 1'b1;

		unique case (access_type)
			PMP_ACCESS_READ:  allowed = entry.read || (mxr && entry.execute);
			PMP_ACCESS_WRITE: allowed = entry.write;
			PMP_ACCESS_EXEC:  allowed = entry.execute;
			default:          allowed = 1'b0;
		endcase

		if (priv_mode == U) begin
			allowed = allowed && entry.user;
		end else if (priv_mode == S) begin
			if (entry.user) begin
				if (access_type == PMP_ACCESS_EXEC) begin
					allowed = 1'b0;
				end else begin
					allowed = allowed && sum;
				end
			end
		end

		allowed = allowed && entry.accessed;
		if (access_type == PMP_ACCESS_WRITE) begin
			allowed = allowed && entry.dirty;
		end

		return allowed;
	endfunction

	always_comb begin
		hit = 1'b0;
		matched_entry = '0;

		for (int unsigned i = 0; i < ENTRY_COUNT; i++) begin
			if (!hit && lookup_valid && entries[i].valid && vpn_matches(entries[i].vpn, entries[i].level, lookup_vpn)) begin
				hit = 1'b1;
				matched_entry = entries[i];
			end
		end

		pa = translated_pa(matched_entry, lookup_va);
		fault = hit && !entry_allows_access(
			matched_entry,
			lookup_access_type,
			lookup_priv_mode,
			lookup_sum,
			lookup_mxr
		);
		fault_detail = fault ? permission_fault_detail(
			matched_entry,
			lookup_access_type,
			lookup_priv_mode,
			lookup_sum,
			lookup_mxr
		) : SV39_FAULT_NONE;
	end

	always_comb begin
		refill_match = 1'b0;
		refill_index = replace_index;

		for (int unsigned i = 0; i < ENTRY_COUNT; i++) begin
			if (!refill_match &&
				entries[i].valid &&
				entries[i].level == refill_level &&
				vpn_matches(entries[i].vpn, entries[i].level, refill_vpn)) begin
				refill_match = 1'b1;
				refill_index = INDEX_WIDTH'(i);
			end
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			for (int unsigned i = 0; i < ENTRY_COUNT; i++) begin
				entries[i] <= '0;
			end
			replace_index <= '0;
		end else if (flush) begin
			for (int unsigned i = 0; i < ENTRY_COUNT; i++) begin
				entries[i].valid <= 1'b0;
			end
			replace_index <= '0;
		end else if (refill_valid) begin
			entries[refill_index].valid <= 1'b1;
			entries[refill_index].vpn <= refill_vpn;
			entries[refill_index].ppn <= refill_ppn;
			entries[refill_index].level <= refill_level;
			entries[refill_index].global_bit <= refill_g;
			entries[refill_index].user <= refill_u;
			entries[refill_index].read <= refill_r;
			entries[refill_index].write <= refill_w;
			entries[refill_index].execute <= refill_x;
			entries[refill_index].accessed <= refill_a;
			entries[refill_index].dirty <= refill_d;

			if (!refill_match) begin
				if (replace_index == INDEX_WIDTH'(ENTRY_COUNT - 1)) begin
					replace_index <= '0;
				end else begin
					replace_index <= replace_index + INDEX_WIDTH'(1);
				end
			end
		end
	end
endmodule : tlb
