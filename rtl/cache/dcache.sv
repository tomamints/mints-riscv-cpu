import eei::*;

module dcache #(
	parameter int unsigned LINE_COUNT = 128,
	parameter int unsigned STORE_BUFFER_DEPTH = 4,
	parameter bit WRITE_BACK = 1'b0
) (
	input logic clk,
	input logic rst,
	input logic invalidate,
	output logic flush_busy,
	output logic mem_low_priority,
	core_data_if.slave cpu,
	core_data_if.master mem
);

	localparam int unsigned INDEX_WIDTH = LINE_COUNT <= 1 ? 1 : $clog2(LINE_COUNT);
	localparam int unsigned LINE_BYTES = 32;
	localparam int unsigned LINE_OFFSET_WIDTH = 5;
	localparam int unsigned WORDS_PER_LINE = LINE_BYTES / 8;
	localparam int unsigned WORD_OFFSET_WIDTH = $clog2(WORDS_PER_LINE);
	localparam int unsigned FILL_COUNT_WIDTH = $clog2(WORDS_PER_LINE + 1);
	localparam int unsigned TAG_WIDTH = XLEN - LINE_OFFSET_WIDTH - INDEX_WIDTH;
	localparam int unsigned STORE_BUFFER_INDEX_WIDTH =
		STORE_BUFFER_DEPTH <= 1 ? 1 : $clog2(STORE_BUFFER_DEPTH);
	localparam int unsigned STORE_BUFFER_COUNT_WIDTH = $clog2(STORE_BUFFER_DEPTH + 1);
	localparam Addr MMAP_RAM_END = MMAP_RAM_BEGIN + (Addr'(1) << RAM_ADDR_WIDTH);

	typedef enum logic [2:0] {
		Idle,
		LoadFillReq,
		LoadFillWait,
		BypassReq,
		BypassWait,
		WritebackReq,
		FlushScan,
		Response
	} State;

	State state;

	logic [LINE_COUNT-1:0] valid;
	logic [LINE_COUNT-1:0] dirty;
	logic [TAG_WIDTH-1:0] tags [LINE_COUNT];
	UInt64 data [LINE_COUNT][WORDS_PER_LINE];

	Addr saved_addr;
	UInt64 saved_wdata;
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] saved_wmask;
	logic saved_wen;
	logic saved_is_amo;
	logic saved_aq;
	logic saved_rl;
	AMOOp saved_amoop;
	logic [2:0] saved_funct3;

	Addr fill_line_addr;
	logic [INDEX_WIDTH-1:0] fill_index;
	logic [TAG_WIDTH-1:0] fill_tag;
	logic [WORD_OFFSET_WIDTH-1:0] fill_next_word;
	logic [WORD_OFFSET_WIDTH-1:0] fill_response_word;
	logic [FILL_COUNT_WIDTH-1:0] fill_count;
	logic [WORDS_PER_LINE-1:0] fill_word_valid;
	UInt64 fill_data [WORDS_PER_LINE];
	logic rsp_valid_q;
	UInt64 rsp_data_q;
	Addr writeback_line_addr;
	logic [INDEX_WIDTH-1:0] writeback_index;
	logic [WORD_OFFSET_WIDTH-1:0] writeback_word;
	logic writeback_resume_bypass;
	logic writeback_resume_flush;
	logic flush_active;
	logic [INDEX_WIDTH-1:0] flush_index;

	Addr store_buffer_addr [STORE_BUFFER_DEPTH];
	UInt64 store_buffer_wdata [STORE_BUFFER_DEPTH];
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] store_buffer_wmask [STORE_BUFFER_DEPTH];
	logic [2:0] store_buffer_funct3 [STORE_BUFFER_DEPTH];
	logic [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_head;
	logic [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_tail;
	logic [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count;
	logic store_buffer_issue_valid;
	logic store_buffer_issue_fire;
	logic store_buffer_full;
	logic store_buffer_full_after_issue;
	logic store_buffer_empty;
	logic [STORE_BUFFER_INDEX_WIDTH-1:0] store_buffer_tail_prev;
	logic cacheable_store_can_enqueue_without_drain;
	logic cacheable_load_can_bypass_store_buffer;
	logic cpu_store_buffer_overlap;
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] cpu_load_mask;
	logic store_buffer_tail_same_word;
	logic store_buffer_tail_mask_disjoint;
	logic store_buffer_any_same_word;
	logic store_buffer_any_same_line;
	logic store_buffer_drain_urgent;
	logic cacheable_store_can_accept_without_drain;
	logic fill_allocate;

	logic [INDEX_WIDTH-1:0] cpu_index;
	logic [TAG_WIDTH-1:0] cpu_tag;
	logic [WORD_OFFSET_WIDTH-1:0] cpu_word_offset;
	Addr cpu_line_addr;
	logic cpu_ram_access;
	logic cpu_cacheable;
	logic cache_hit;
	logic dirty_victim_hit;
	Addr cpu_victim_line_addr;
	logic [INDEX_WIDTH-1:0] fast_load_index;
	logic [TAG_WIDTH-1:0] fast_load_tag;
	logic [WORD_OFFSET_WIDTH-1:0] fast_load_word_offset;
	logic fast_load_cacheable;
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] fast_load_mask;
	logic fast_load_store_buffer_overlap;
	logic fast_load_hit;

	UInt64 perf_req_count;
	UInt64 perf_load_req_count;
	UInt64 perf_store_req_count;
	UInt64 perf_cacheable_req_count;
	UInt64 perf_hit_count;
	UInt64 perf_miss_count;
	UInt64 perf_load_hit_count;
	UInt64 perf_load_miss_count;
	UInt64 perf_store_hit_count;
	UInt64 perf_store_miss_count;
	UInt64 perf_uncached_count;
	UInt64 perf_bypass_count;
	UInt64 perf_write_through_count;
	UInt64 perf_store_buffer_enq_count;
	UInt64 perf_store_buffer_drain_count;
	UInt64 perf_store_buffer_full_stall_count;
	UInt64 perf_store_buffer_load_bypass_count;
	UInt64 perf_store_buffer_load_wait_count;
	UInt64 perf_mem_req_count;
	UInt64 perf_mem_resp_count;
	UInt64 perf_flush_count;
	UInt64 perf_load_miss_stall_cycle;
	UInt64 perf_uncached_stall_cycle;
	UInt64 perf_cpu_wait_busy_cycle;
	UInt64 perf_cpu_wait_rsp_pending_cycle;
	UInt64 perf_cpu_wait_store_full_cycle;
	UInt64 perf_cpu_wait_load_overlap_cycle;
	UInt64 perf_cpu_wait_load_store_empty_cycle;
	UInt64 perf_cpu_wait_uncached_store_empty_cycle;
	UInt64 perf_cpu_wait_other_cycle;
	UInt64 perf_load_fill_req_wait_cycle;
	UInt64 perf_load_fill_rsp_wait_cycle;
	UInt64 perf_bypass_req_wait_cycle;
	UInt64 perf_bypass_rsp_wait_cycle;
	UInt64 perf_store_drain_req_wait_cycle;
	UInt64 perf_store_drain_active_cycle;
	UInt64 perf_store_drain_urgent_active_cycle;
	UInt64 perf_store_drain_urgent_wait_cycle;
	UInt64 perf_store_drain_low_active_cycle;
	UInt64 perf_store_drain_low_wait_cycle;
	UInt64 perf_store_buffer_occ_empty_cycle;
	UInt64 perf_store_buffer_occ_one_cycle;
	UInt64 perf_store_buffer_occ_two_cycle;
	UInt64 perf_store_buffer_occ_almost_full_cycle;
	UInt64 perf_store_buffer_occ_full_cycle;
	UInt64 perf_store_combine_candidate_count;
	UInt64 perf_store_combine_tail_word_count;
	UInt64 perf_store_combine_tail_disjoint_count;
	UInt64 perf_store_combine_any_word_count;
	UInt64 perf_store_combine_any_line_count;
	UInt64 perf_response_cache_hit_load_count;
	UInt64 perf_response_fill_critical_count;
	UInt64 perf_response_bypass_load_count;
	UInt64 perf_response_bypass_amo_count;
	UInt64 perf_fast_load_hit_count;
	UInt64 perf_write_back_store_hit_count;
	UInt64 perf_write_back_evict_count;
	UInt64 perf_write_back_word_count;
	UInt64 perf_write_back_req_wait_cycle;
	UInt64 perf_wb_flush_clean_count;
	UInt64 perf_wb_flush_dirty_count;
	UInt64 perf_wb_flush_scan_cycle;
	UInt64 perf_wb_flush_dirty_line_count;
	UInt64 perf_wb_flush_word_count;
	UInt64 perf_wb_flush_req_wait_cycle;

	function automatic logic dirty_any();
		dirty_any = 1'b0;
		for (int unsigned i = 0; i < LINE_COUNT; i++) begin
			if (valid[i] && dirty[i]) begin
				dirty_any = 1'b1;
			end
		end
	endfunction

	function automatic logic is_ram(input Addr paddr);
		return paddr >= MMAP_RAM_BEGIN && paddr < MMAP_RAM_END;
	endfunction

	function automatic UInt64 merge_word(
		input UInt64 old_data,
		input UInt64 new_data,
		input logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask
	);
		logic [MEMBUS_DATA_WIDTH-1:0] expanded;
		for (int i = 0; i < MEMBUS_DATA_WIDTH; i++) begin
			expanded[i] = wmask[i / 8];
		end
		return (new_data & expanded) | (old_data & ~expanded);
	endfunction

	function automatic logic [(MEMBUS_DATA_WIDTH/8)-1:0] access_byte_mask(
		input logic [2:0] funct3,
		input logic [2:0] offset
	);
		logic [3:0] size;
		logic [3:0] available;
		logic [3:0] bytes;
		logic [(MEMBUS_DATA_WIDTH/8)-1:0] base_mask;

		size = 4'(1 << funct3[1:0]);
		available = 4'd8 - {1'b0, offset};
		bytes = (size < available) ? size : available;
		base_mask = '0;
		for (int unsigned i = 0; i < MEMBUS_DATA_WIDTH / 8; i++) begin
			if (i < bytes) begin
				base_mask[i] = 1'b1;
			end
		end
		return base_mask << offset;
	endfunction

	function automatic logic store_buffer_overlaps(
		input Addr addr,
		input logic [(MEMBUS_DATA_WIDTH/8)-1:0] mask
	);
		logic [STORE_BUFFER_INDEX_WIDTH-1:0] idx;

		store_buffer_overlaps = 1'b0;
		for (int unsigned i = 0; i < STORE_BUFFER_DEPTH; i++) begin
			idx = store_buffer_head + STORE_BUFFER_INDEX_WIDTH'(i);
			if (i < store_buffer_count &&
				store_buffer_addr[idx][XLEN-1:3] == addr[XLEN-1:3] &&
				(store_buffer_wmask[idx] & mask) != '0) begin
				store_buffer_overlaps = 1'b1;
			end
		end
	endfunction

	function automatic logic store_buffer_has_same_word(input Addr addr);
		logic [STORE_BUFFER_INDEX_WIDTH-1:0] idx;

		store_buffer_has_same_word = 1'b0;
		for (int unsigned i = 0; i < STORE_BUFFER_DEPTH; i++) begin
			idx = store_buffer_head + STORE_BUFFER_INDEX_WIDTH'(i);
			if (i < store_buffer_count &&
				store_buffer_addr[idx][XLEN-1:3] == addr[XLEN-1:3]) begin
				store_buffer_has_same_word = 1'b1;
			end
		end
	endfunction

	function automatic logic store_buffer_has_same_line(input Addr addr);
		logic [STORE_BUFFER_INDEX_WIDTH-1:0] idx;

		store_buffer_has_same_line = 1'b0;
		for (int unsigned i = 0; i < STORE_BUFFER_DEPTH; i++) begin
			idx = store_buffer_head + STORE_BUFFER_INDEX_WIDTH'(i);
			if (i < store_buffer_count &&
				store_buffer_addr[idx][XLEN-1:LINE_OFFSET_WIDTH] ==
					addr[XLEN-1:LINE_OFFSET_WIDTH]) begin
				store_buffer_has_same_line = 1'b1;
			end
		end
	endfunction

	assign cpu_line_addr = {cpu.addr[XLEN-1:LINE_OFFSET_WIDTH], {LINE_OFFSET_WIDTH{1'b0}}};
	assign cpu_index = cpu.addr[LINE_OFFSET_WIDTH +: INDEX_WIDTH];
	assign cpu_tag = cpu.addr[XLEN-1 -: TAG_WIDTH];
	assign cpu_word_offset = cpu.addr[3 +: WORD_OFFSET_WIDTH];
	assign cpu_ram_access = is_ram(cpu.addr);
	assign cpu_cacheable = cpu_ram_access && !cpu.is_amo;
	assign cache_hit = cpu_cacheable && valid[cpu_index] && tags[cpu_index] == cpu_tag;
	assign dirty_victim_hit = WRITE_BACK && valid[cpu_index] && dirty[cpu_index];
	assign cpu_victim_line_addr = Addr'({tags[cpu_index], cpu_index, {LINE_OFFSET_WIDTH{1'b0}}});
	assign store_buffer_tail_prev = store_buffer_tail - STORE_BUFFER_INDEX_WIDTH'(1);
	assign fast_load_index = cpu.fast_load_addr[LINE_OFFSET_WIDTH +: INDEX_WIDTH];
	assign fast_load_tag = cpu.fast_load_addr[XLEN-1 -: TAG_WIDTH];
	assign fast_load_word_offset = cpu.fast_load_addr[3 +: WORD_OFFSET_WIDTH];
	assign fast_load_cacheable = is_ram(cpu.fast_load_addr);
	assign fast_load_mask = access_byte_mask(cpu.fast_load_funct3, cpu.fast_load_addr[2:0]);
	assign fast_load_store_buffer_overlap = store_buffer_overlaps(cpu.fast_load_addr, fast_load_mask);
	assign fast_load_hit =
		cpu.fast_load_req &&
		state == Idle &&
		!flush_active &&
		!invalidate &&
		!rsp_valid_q &&
		fast_load_cacheable &&
		valid[fast_load_index] &&
		tags[fast_load_index] == fast_load_tag &&
		!fast_load_store_buffer_overlap;
	assign store_buffer_full = store_buffer_count == STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_DEPTH);
	assign cpu_load_mask = access_byte_mask(cpu.funct3, cpu.addr[2:0]);
	assign cpu_store_buffer_overlap = store_buffer_overlaps(cpu.addr, cpu_load_mask);
	assign store_buffer_tail_same_word =
		store_buffer_count != '0 &&
		store_buffer_addr[store_buffer_tail_prev][XLEN-1:3] == cpu.addr[XLEN-1:3];
	assign store_buffer_tail_mask_disjoint =
		store_buffer_tail_same_word &&
		(store_buffer_wmask[store_buffer_tail_prev] & cpu.wmask) == '0;
	assign store_buffer_any_same_word = store_buffer_has_same_word(cpu.addr);
	assign store_buffer_any_same_line = store_buffer_has_same_line(cpu.addr);
	assign cacheable_store_can_accept_without_drain =
		cpu.valid &&
		cpu_cacheable &&
		cpu.wen &&
		((WRITE_BACK && cache_hit) || !store_buffer_full);
	assign cacheable_store_can_enqueue_without_drain =
		cpu.valid &&
		cpu_cacheable &&
		cpu.wen &&
		!(WRITE_BACK && cache_hit) &&
		!store_buffer_full;
	assign cacheable_load_can_bypass_store_buffer =
		cpu.valid &&
		cpu_cacheable &&
		!cpu.wen &&
		cache_hit &&
		!cpu_store_buffer_overlap;
	assign store_buffer_issue_valid =
		state == Idle &&
		store_buffer_count != '0 &&
		(flush_active ||
		 (!cacheable_store_can_accept_without_drain &&
		  !cacheable_load_can_bypass_store_buffer));
	assign store_buffer_issue_fire = store_buffer_issue_valid && mem.ready;
	assign store_buffer_full_after_issue =
		store_buffer_full &&
		!store_buffer_issue_fire;
	assign store_buffer_empty = store_buffer_count == '0;
	assign store_buffer_drain_urgent =
		store_buffer_count >= STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_DEPTH - 1) ||
		(cpu.valid && !(cpu_cacheable && cpu.wen));

	assign cpu.ready =
		state == Idle &&
		!flush_active &&
		!rsp_valid_q &&
		((cpu_cacheable && cpu.wen) ? ((WRITE_BACK && cache_hit) || !store_buffer_full_after_issue) :
			(cacheable_load_can_bypass_store_buffer || store_buffer_empty));
	assign flush_busy = WRITE_BACK && flush_active;

	always_comb begin
		cpu.rvalid = rsp_valid_q;
		cpu.rdata = rsp_data_q;
		cpu.fast_load_valid = fast_load_hit;
		cpu.fast_load_data = data[fast_load_index][fast_load_word_offset];

		mem.valid = 1'b0;
		mem.addr = '0;
		mem.wen = 1'b0;
		mem.wdata = '0;
		mem.wmask = '0;
		mem.is_amo = 1'b0;
		mem.aq = 1'b0;
		mem.rl = 1'b0;
		mem.amoop = AMOOp'(0);
		mem.funct3 = 3'b011;
		mem.fast_load_req = 1'b0;
		mem.fast_load_addr = '0;
		mem.fast_load_funct3 = 3'b011;
		mem_low_priority = 1'b0;

		unique case (state)
			Idle: begin
				if (store_buffer_issue_valid) begin
					mem.valid = 1'b1;
					mem.addr = store_buffer_addr[store_buffer_head];
					mem.wen = 1'b1;
					mem.wdata = store_buffer_wdata[store_buffer_head];
					mem.wmask = store_buffer_wmask[store_buffer_head];
					mem.funct3 = store_buffer_funct3[store_buffer_head];
					mem_low_priority = !store_buffer_drain_urgent;
				end else if (cpu.valid && cpu.ready) begin
					if (cpu.is_amo || !cpu_cacheable) begin
						mem.valid = 1'b1;
						mem.addr = cpu.addr;
						mem.wen = cpu.wen;
						mem.wdata = cpu.wdata;
						mem.wmask = cpu.wmask;
						mem.is_amo = cpu.is_amo;
						mem.aq = cpu.aq;
						mem.rl = cpu.rl;
						mem.amoop = cpu.amoop;
						mem.funct3 = cpu.funct3;
					end
				end
			end

			LoadFillReq: begin
				mem.valid = 1'b1;
				mem.addr = fill_line_addr + (Addr'(fill_next_word) << 3);
				mem.wen = 1'b0;
				mem.funct3 = 3'b011;
			end

			BypassReq: begin
				mem.valid = 1'b1;
				mem.addr = saved_addr;
				mem.wen = saved_wen;
				mem.wdata = saved_wdata;
				mem.wmask = saved_wmask;
				mem.is_amo = saved_is_amo;
				mem.aq = saved_aq;
				mem.rl = saved_rl;
				mem.amoop = saved_amoop;
				mem.funct3 = saved_funct3;
			end

			BypassWait: begin
			end

			WritebackReq: begin
				mem.valid = 1'b1;
				mem.addr = writeback_line_addr + (Addr'(writeback_word) << 3);
				mem.wen = 1'b1;
				mem.wdata = data[writeback_index][writeback_word];
				mem.wmask = '1;
				mem.funct3 = 3'b011;
			end

			FlushScan: begin
			end

			LoadFillWait: begin
			end

			Response: begin
			end

			default: begin
			end
		endcase
	end

	initial begin
		if (LINE_COUNT < 2 || (LINE_COUNT & (LINE_COUNT - 1)) != 0) begin
			$fatal(1, "DCACHE LINE_COUNT must be a power of two and at least 2");
		end
		if (STORE_BUFFER_DEPTH < 2 || (STORE_BUFFER_DEPTH & (STORE_BUFFER_DEPTH - 1)) != 0) begin
			$fatal(1, "DCACHE STORE_BUFFER_DEPTH must be a power of two and at least 2");
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Idle;
			saved_addr <= '0;
			saved_wdata <= '0;
			saved_wmask <= '0;
			saved_wen <= 1'b0;
			saved_is_amo <= 1'b0;
			saved_aq <= 1'b0;
			saved_rl <= 1'b0;
			saved_amoop <= AMOOp'(0);
			saved_funct3 <= '0;
			fill_line_addr <= '0;
			fill_index <= '0;
			fill_tag <= '0;
			fill_next_word <= '0;
			fill_response_word <= '0;
			fill_count <= '0;
			fill_word_valid <= '0;
			rsp_valid_q <= 1'b0;
			rsp_data_q <= '0;
			writeback_line_addr <= '0;
			writeback_index <= '0;
			writeback_word <= '0;
			writeback_resume_bypass <= 1'b0;
			writeback_resume_flush <= 1'b0;
			flush_active <= 1'b0;
			flush_index <= '0;
			store_buffer_head <= '0;
			store_buffer_tail <= '0;
			store_buffer_count <= '0;
			fill_allocate <= 1'b0;
			perf_req_count <= '0;
			perf_load_req_count <= '0;
			perf_store_req_count <= '0;
			perf_cacheable_req_count <= '0;
			perf_hit_count <= '0;
			perf_miss_count <= '0;
			perf_load_hit_count <= '0;
			perf_load_miss_count <= '0;
			perf_store_hit_count <= '0;
			perf_store_miss_count <= '0;
			perf_uncached_count <= '0;
			perf_bypass_count <= '0;
			perf_write_through_count <= '0;
			perf_store_buffer_enq_count <= '0;
			perf_store_buffer_drain_count <= '0;
			perf_store_buffer_full_stall_count <= '0;
			perf_store_buffer_load_bypass_count <= '0;
			perf_store_buffer_load_wait_count <= '0;
			perf_mem_req_count <= '0;
			perf_mem_resp_count <= '0;
			perf_flush_count <= '0;
			perf_load_miss_stall_cycle <= '0;
			perf_uncached_stall_cycle <= '0;
			perf_cpu_wait_busy_cycle <= '0;
			perf_cpu_wait_rsp_pending_cycle <= '0;
			perf_cpu_wait_store_full_cycle <= '0;
			perf_cpu_wait_load_overlap_cycle <= '0;
			perf_cpu_wait_load_store_empty_cycle <= '0;
			perf_cpu_wait_uncached_store_empty_cycle <= '0;
			perf_cpu_wait_other_cycle <= '0;
			perf_load_fill_req_wait_cycle <= '0;
			perf_load_fill_rsp_wait_cycle <= '0;
			perf_bypass_req_wait_cycle <= '0;
			perf_bypass_rsp_wait_cycle <= '0;
			perf_store_drain_req_wait_cycle <= '0;
			perf_store_drain_active_cycle <= '0;
			perf_store_drain_urgent_active_cycle <= '0;
			perf_store_drain_urgent_wait_cycle <= '0;
			perf_store_drain_low_active_cycle <= '0;
			perf_store_drain_low_wait_cycle <= '0;
			perf_store_buffer_occ_empty_cycle <= '0;
			perf_store_buffer_occ_one_cycle <= '0;
			perf_store_buffer_occ_two_cycle <= '0;
			perf_store_buffer_occ_almost_full_cycle <= '0;
			perf_store_buffer_occ_full_cycle <= '0;
			perf_store_combine_candidate_count <= '0;
			perf_store_combine_tail_word_count <= '0;
			perf_store_combine_tail_disjoint_count <= '0;
			perf_store_combine_any_word_count <= '0;
			perf_store_combine_any_line_count <= '0;
			perf_response_cache_hit_load_count <= '0;
			perf_response_fill_critical_count <= '0;
			perf_response_bypass_load_count <= '0;
			perf_response_bypass_amo_count <= '0;
			perf_fast_load_hit_count <= '0;
			perf_write_back_store_hit_count <= '0;
			perf_write_back_evict_count <= '0;
			perf_write_back_word_count <= '0;
			perf_write_back_req_wait_cycle <= '0;
			perf_wb_flush_clean_count <= '0;
			perf_wb_flush_dirty_count <= '0;
			perf_wb_flush_scan_cycle <= '0;
			perf_wb_flush_dirty_line_count <= '0;
			perf_wb_flush_word_count <= '0;
			perf_wb_flush_req_wait_cycle <= '0;
			for (int unsigned i = 0; i < LINE_COUNT; i++) begin
				valid[i] <= 1'b0;
				dirty[i] <= 1'b0;
			end
		end else begin
			logic [STORE_BUFFER_COUNT_WIDTH-1:0] store_buffer_count_next;

			store_buffer_count_next = store_buffer_count;
			rsp_valid_q <= 1'b0;

			if (store_buffer_count == '0) begin
				perf_store_buffer_occ_empty_cycle <= perf_store_buffer_occ_empty_cycle + UInt64'(1);
			end else if (store_buffer_count == STORE_BUFFER_COUNT_WIDTH'(STORE_BUFFER_DEPTH)) begin
				perf_store_buffer_occ_full_cycle <= perf_store_buffer_occ_full_cycle + UInt64'(1);
			end else if (store_buffer_count == STORE_BUFFER_COUNT_WIDTH'(1)) begin
				perf_store_buffer_occ_one_cycle <= perf_store_buffer_occ_one_cycle + UInt64'(1);
			end else if (store_buffer_count == STORE_BUFFER_COUNT_WIDTH'(2)) begin
				perf_store_buffer_occ_two_cycle <= perf_store_buffer_occ_two_cycle + UInt64'(1);
			end else begin
				perf_store_buffer_occ_almost_full_cycle <= perf_store_buffer_occ_almost_full_cycle + UInt64'(1);
			end

			if (state == LoadFillReq || state == LoadFillWait) begin
				perf_load_miss_stall_cycle <= perf_load_miss_stall_cycle + UInt64'(1);
			end
			if (state == BypassReq || state == BypassWait) begin
				perf_uncached_stall_cycle <= perf_uncached_stall_cycle + UInt64'(1);
			end
			if (state == LoadFillReq && !mem.ready) begin
				perf_load_fill_req_wait_cycle <= perf_load_fill_req_wait_cycle + UInt64'(1);
			end
			if (state == LoadFillWait && !mem.rvalid) begin
				perf_load_fill_rsp_wait_cycle <= perf_load_fill_rsp_wait_cycle + UInt64'(1);
			end
			if (state == BypassReq && !mem.ready) begin
				perf_bypass_req_wait_cycle <= perf_bypass_req_wait_cycle + UInt64'(1);
			end
			if (state == BypassWait && !mem.rvalid) begin
				perf_bypass_rsp_wait_cycle <= perf_bypass_rsp_wait_cycle + UInt64'(1);
			end
			if (state == WritebackReq && !mem.ready) begin
				perf_write_back_req_wait_cycle <= perf_write_back_req_wait_cycle + UInt64'(1);
				if (writeback_resume_flush) begin
					perf_wb_flush_req_wait_cycle <= perf_wb_flush_req_wait_cycle + UInt64'(1);
				end
			end
			if (state == FlushScan) begin
				perf_wb_flush_scan_cycle <= perf_wb_flush_scan_cycle + UInt64'(1);
			end
			if (store_buffer_issue_valid) begin
				perf_store_drain_active_cycle <= perf_store_drain_active_cycle + UInt64'(1);
				if (store_buffer_drain_urgent) begin
					perf_store_drain_urgent_active_cycle <= perf_store_drain_urgent_active_cycle + UInt64'(1);
				end else begin
					perf_store_drain_low_active_cycle <= perf_store_drain_low_active_cycle + UInt64'(1);
				end
				if (!mem.ready) begin
					perf_store_drain_req_wait_cycle <= perf_store_drain_req_wait_cycle + UInt64'(1);
					if (store_buffer_drain_urgent) begin
						perf_store_drain_urgent_wait_cycle <= perf_store_drain_urgent_wait_cycle + UInt64'(1);
					end else begin
						perf_store_drain_low_wait_cycle <= perf_store_drain_low_wait_cycle + UInt64'(1);
					end
				end
			end
			if (cpu.valid && !cpu.ready) begin
				if (state != Idle) begin
					perf_cpu_wait_busy_cycle <= perf_cpu_wait_busy_cycle + UInt64'(1);
				end else if (rsp_valid_q) begin
					perf_cpu_wait_rsp_pending_cycle <= perf_cpu_wait_rsp_pending_cycle + UInt64'(1);
				end else if (cpu_cacheable && cpu.wen && store_buffer_full_after_issue) begin
					perf_cpu_wait_store_full_cycle <= perf_cpu_wait_store_full_cycle + UInt64'(1);
				end else if (cpu_cacheable && !cpu.wen && store_buffer_count != '0 && cpu_store_buffer_overlap) begin
					perf_cpu_wait_load_overlap_cycle <= perf_cpu_wait_load_overlap_cycle + UInt64'(1);
				end else if (cpu_cacheable && !cpu.wen && store_buffer_count != '0) begin
					perf_cpu_wait_load_store_empty_cycle <= perf_cpu_wait_load_store_empty_cycle + UInt64'(1);
				end else if ((!cpu_cacheable || cpu.is_amo) && store_buffer_count != '0) begin
					perf_cpu_wait_uncached_store_empty_cycle <= perf_cpu_wait_uncached_store_empty_cycle + UInt64'(1);
				end else begin
					perf_cpu_wait_other_cycle <= perf_cpu_wait_other_cycle + UInt64'(1);
				end
			end

			if (store_buffer_issue_fire) begin
				store_buffer_head <= store_buffer_head + STORE_BUFFER_INDEX_WIDTH'(1);
				store_buffer_count_next = store_buffer_count_next - STORE_BUFFER_COUNT_WIDTH'(1);
				perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
				perf_store_buffer_drain_count <= perf_store_buffer_drain_count + UInt64'(1);
			end

			if (state == Idle && cpu.valid && cpu_cacheable && cpu.wen && store_buffer_full_after_issue) begin
				perf_store_buffer_full_stall_count <= perf_store_buffer_full_stall_count + UInt64'(1);
			end
			if (state == Idle && cpu.valid && cpu_cacheable && !cpu.wen && store_buffer_count != '0) begin
				if (cacheable_load_can_bypass_store_buffer) begin
					perf_store_buffer_load_bypass_count <= perf_store_buffer_load_bypass_count + UInt64'(1);
				end else begin
					perf_store_buffer_load_wait_count <= perf_store_buffer_load_wait_count + UInt64'(1);
				end
			end
			if (cpu.fast_load_req && cpu.fast_load_valid) begin
				perf_req_count <= perf_req_count + UInt64'(1);
				perf_load_req_count <= perf_load_req_count + UInt64'(1);
				perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
				perf_hit_count <= perf_hit_count + UInt64'(1);
				perf_load_hit_count <= perf_load_hit_count + UInt64'(1);
				perf_response_cache_hit_load_count <=
					perf_response_cache_hit_load_count + UInt64'(1);
				perf_fast_load_hit_count <= perf_fast_load_hit_count + UInt64'(1);
			end

			if (invalidate && !flush_active) begin
				fill_word_valid <= '0;
				fill_allocate <= 1'b0;
				perf_flush_count <= perf_flush_count + UInt64'(1);
				if (WRITE_BACK) begin
					if (dirty_any() || store_buffer_count_next != '0) begin
						flush_active <= 1'b1;
						flush_index <= '0;
						writeback_resume_bypass <= 1'b0;
						writeback_resume_flush <= 1'b0;
						perf_wb_flush_dirty_count <= perf_wb_flush_dirty_count + UInt64'(1);
						if (state != WritebackReq && state != BypassReq && state != BypassWait) begin
							state <= Idle;
						end
					end else begin
						perf_wb_flush_clean_count <= perf_wb_flush_clean_count + UInt64'(1);
					end
				end else begin
					for (int unsigned i = 0; i < LINE_COUNT; i++) begin
						valid[i] <= 1'b0;
						dirty[i] <= 1'b0;
					end
				end
			end

			if (!invalidate) begin
			unique case (state)
				Idle: begin
					if (flush_active) begin
						if (store_buffer_count_next == '0) begin
							state <= FlushScan;
						end
					end else if (cpu.valid && cpu.ready) begin
						perf_req_count <= perf_req_count + UInt64'(1);
						if (cpu.wen) begin
							perf_store_req_count <= perf_store_req_count + UInt64'(1);
						end else begin
							perf_load_req_count <= perf_load_req_count + UInt64'(1);
						end

						saved_addr <= cpu.addr;
						saved_wdata <= cpu.wdata;
						saved_wmask <= cpu.wmask;
						saved_wen <= cpu.wen;
						saved_is_amo <= cpu.is_amo;
						saved_aq <= cpu.aq;
						saved_rl <= cpu.rl;
						saved_amoop <= cpu.amoop;
						saved_funct3 <= cpu.funct3;

						if (cpu.is_amo &&
							cpu_ram_access &&
							valid[cpu_index] &&
							tags[cpu_index] == cpu_tag &&
							!(WRITE_BACK && dirty[cpu_index])) begin
							valid[cpu_index] <= 1'b0;
							dirty[cpu_index] <= 1'b0;
						end

						if (cpu_cacheable) begin
							perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
						end else begin
							perf_uncached_count <= perf_uncached_count + UInt64'(1);
						end

						if (WRITE_BACK &&
							cpu.is_amo &&
							cpu_ram_access &&
							valid[cpu_index] &&
							tags[cpu_index] == cpu_tag &&
							dirty[cpu_index]) begin
							perf_bypass_count <= perf_bypass_count + UInt64'(1);
							writeback_line_addr <= cpu_victim_line_addr;
							writeback_index <= cpu_index;
							writeback_word <= '0;
							writeback_resume_bypass <= 1'b1;
							perf_write_back_evict_count <= perf_write_back_evict_count + UInt64'(1);
							state <= WritebackReq;
						end else if (cpu_cacheable && !cpu.wen && cache_hit) begin
							rsp_data_q <= data[cpu_index][cpu_word_offset];
							rsp_valid_q <= 1'b1;
							perf_hit_count <= perf_hit_count + UInt64'(1);
							perf_load_hit_count <= perf_load_hit_count + UInt64'(1);
							perf_response_cache_hit_load_count <=
								perf_response_cache_hit_load_count + UInt64'(1);
							state <= Response;
						end else if (cpu_cacheable && !cpu.wen) begin
							perf_miss_count <= perf_miss_count + UInt64'(1);
							perf_load_miss_count <= perf_load_miss_count + UInt64'(1);
							fill_line_addr <= cpu_line_addr;
							fill_index <= cpu_index;
							fill_tag <= cpu_tag;
							fill_next_word <= cpu_word_offset;
							fill_response_word <= cpu_word_offset;
							fill_count <= '0;
							fill_word_valid <= '0;
							fill_allocate <= 1'b1;
							if (dirty_victim_hit) begin
								writeback_line_addr <= cpu_victim_line_addr;
								writeback_index <= cpu_index;
								writeback_word <= '0;
								writeback_resume_bypass <= 1'b0;
								perf_write_back_evict_count <= perf_write_back_evict_count + UInt64'(1);
								state <= WritebackReq;
							end else begin
								state <= LoadFillReq;
							end
						end else if (cpu_cacheable && cpu.wen) begin
							perf_store_combine_candidate_count <=
								perf_store_combine_candidate_count + UInt64'(1);
							if (store_buffer_tail_same_word) begin
								perf_store_combine_tail_word_count <=
									perf_store_combine_tail_word_count + UInt64'(1);
								if (store_buffer_tail_mask_disjoint) begin
									perf_store_combine_tail_disjoint_count <=
										perf_store_combine_tail_disjoint_count + UInt64'(1);
								end
							end
							if (store_buffer_any_same_word) begin
								perf_store_combine_any_word_count <=
									perf_store_combine_any_word_count + UInt64'(1);
							end
							if (store_buffer_any_same_line) begin
								perf_store_combine_any_line_count <=
									perf_store_combine_any_line_count + UInt64'(1);
							end
							if (cache_hit) begin
								perf_hit_count <= perf_hit_count + UInt64'(1);
								perf_store_hit_count <= perf_store_hit_count + UInt64'(1);
								data[cpu_index][cpu_word_offset] <= merge_word(
									data[cpu_index][cpu_word_offset],
									cpu.wdata,
									cpu.wmask);
								if (WRITE_BACK) begin
									dirty[cpu_index] <= 1'b1;
									perf_write_back_store_hit_count <=
										perf_write_back_store_hit_count + UInt64'(1);
								end
							end else begin
								perf_miss_count <= perf_miss_count + UInt64'(1);
								perf_store_miss_count <= perf_store_miss_count + UInt64'(1);
							end
							if (!(WRITE_BACK && cache_hit)) begin
								perf_write_through_count <= perf_write_through_count + UInt64'(1);
								store_buffer_addr[store_buffer_tail] <= cpu.addr;
								store_buffer_wdata[store_buffer_tail] <= cpu.wdata;
								store_buffer_wmask[store_buffer_tail] <= cpu.wmask;
								store_buffer_funct3[store_buffer_tail] <= cpu.funct3;
								store_buffer_tail <= store_buffer_tail + STORE_BUFFER_INDEX_WIDTH'(1);
								store_buffer_count_next =
									store_buffer_count_next + STORE_BUFFER_COUNT_WIDTH'(1);
								perf_store_buffer_enq_count <=
									perf_store_buffer_enq_count + UInt64'(1);
							end
							state <= Idle;
						end else begin
							perf_bypass_count <= perf_bypass_count + UInt64'(1);
							if (mem.ready) begin
								perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
								state <= (cpu.wen && !cpu.is_amo) ? Idle : BypassWait;
							end else begin
								state <= BypassReq;
							end
						end
					end
				end

				LoadFillReq: begin
					if (mem.ready) begin
						perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
						state <= LoadFillWait;
					end
				end

				LoadFillWait: begin
					if (mem.rvalid) begin
						perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
						fill_data[fill_next_word] <= mem.rdata;
						fill_word_valid[fill_next_word] <= 1'b1;
						if (fill_next_word == fill_response_word) begin
							rsp_data_q <= mem.rdata;
							rsp_valid_q <= 1'b1;
							perf_response_fill_critical_count <=
								perf_response_fill_critical_count + UInt64'(1);
						end

						if (fill_count == FILL_COUNT_WIDTH'(WORDS_PER_LINE - 1)) begin
							if (fill_allocate) begin
								valid[fill_index] <= 1'b1;
								dirty[fill_index] <= 1'b0;
								tags[fill_index] <= fill_tag;
								for (int unsigned i = 0; i < WORDS_PER_LINE; i++) begin
									data[fill_index][i] <= (WORD_OFFSET_WIDTH'(i) == fill_next_word) ? mem.rdata : fill_data[i];
								end
							end
							fill_allocate <= 1'b0;
							state <= Idle;
						end else begin
							fill_next_word <= fill_next_word + WORD_OFFSET_WIDTH'(1);
							fill_count <= fill_count + FILL_COUNT_WIDTH'(1);
							state <= LoadFillReq;
						end
					end
				end

				WritebackReq: begin
					if (mem.ready) begin
							perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
							perf_write_back_word_count <= perf_write_back_word_count + UInt64'(1);
							if (writeback_resume_flush) begin
								perf_wb_flush_word_count <= perf_wb_flush_word_count + UInt64'(1);
							end
							if (writeback_word == WORD_OFFSET_WIDTH'(WORDS_PER_LINE - 1)) begin
							dirty[writeback_index] <= 1'b0;
							if (writeback_resume_flush) begin
								valid[writeback_index] <= 1'b0;
								writeback_resume_flush <= 1'b0;
								if (writeback_index == INDEX_WIDTH'(LINE_COUNT - 1)) begin
									flush_active <= 1'b0;
									state <= Idle;
								end else begin
									flush_index <= writeback_index + INDEX_WIDTH'(1);
									state <= FlushScan;
								end
							end else if (writeback_resume_bypass) begin
								valid[writeback_index] <= 1'b0;
								writeback_resume_bypass <= 1'b0;
								state <= BypassReq;
							end else begin
								state <= LoadFillReq;
							end
						end else begin
							writeback_word <= writeback_word + WORD_OFFSET_WIDTH'(1);
						end
					end
				end

				FlushScan: begin
					if (!flush_active) begin
						state <= Idle;
					end else if (flush_index == INDEX_WIDTH'(LINE_COUNT - 1)) begin
						if (valid[flush_index] && dirty[flush_index]) begin
							writeback_line_addr <=
								Addr'({tags[flush_index], flush_index, {LINE_OFFSET_WIDTH{1'b0}}});
							writeback_index <= flush_index;
							writeback_word <= '0;
							writeback_resume_bypass <= 1'b0;
							writeback_resume_flush <= 1'b1;
							perf_write_back_evict_count <= perf_write_back_evict_count + UInt64'(1);
							perf_wb_flush_dirty_line_count <= perf_wb_flush_dirty_line_count + UInt64'(1);
							state <= WritebackReq;
						end else begin
							valid[flush_index] <= 1'b0;
							dirty[flush_index] <= 1'b0;
							flush_active <= 1'b0;
							state <= Idle;
						end
					end else if (valid[flush_index] && dirty[flush_index]) begin
						writeback_line_addr <=
							Addr'({tags[flush_index], flush_index, {LINE_OFFSET_WIDTH{1'b0}}});
						writeback_index <= flush_index;
						writeback_word <= '0;
						writeback_resume_bypass <= 1'b0;
						writeback_resume_flush <= 1'b1;
						perf_write_back_evict_count <= perf_write_back_evict_count + UInt64'(1);
						perf_wb_flush_dirty_line_count <= perf_wb_flush_dirty_line_count + UInt64'(1);
						state <= WritebackReq;
					end else begin
						valid[flush_index] <= 1'b0;
						dirty[flush_index] <= 1'b0;
						flush_index <= flush_index + INDEX_WIDTH'(1);
					end
				end

				BypassReq: begin
					if (mem.ready) begin
						perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
						state <= (saved_wen && !saved_is_amo) ? Idle : BypassWait;
					end
				end

				BypassWait: begin
					if (mem.rvalid) begin
						perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
						if (!saved_wen || saved_is_amo) begin
							rsp_data_q <= mem.rdata;
							rsp_valid_q <= 1'b1;
							if (saved_is_amo) begin
								perf_response_bypass_amo_count <=
									perf_response_bypass_amo_count + UInt64'(1);
							end else begin
								perf_response_bypass_load_count <=
									perf_response_bypass_load_count + UInt64'(1);
							end
							state <= Response;
						end else begin
							state <= Idle;
						end
					end
				end

				Response: begin
					state <= Idle;
				end

				default: state <= Idle;
			endcase
			end

			store_buffer_count <= store_buffer_count_next;
		end
	end

	final begin
		if ($test$plusargs("PERF_SUMMARY")) begin
			$display("[PERF-DCACHE] req=%0d load=%0d store=%0d cacheable=%0d hit=%0d miss=%0d uncached=%0d bypass=%0d hit_rate_x1000=%0d flush=%0d",
				perf_req_count,
				perf_load_req_count,
				perf_store_req_count,
				perf_cacheable_req_count,
				perf_hit_count,
				perf_miss_count,
				perf_uncached_count,
				perf_bypass_count,
				(perf_cacheable_req_count == 0) ? UInt64'(0) : (perf_hit_count * UInt64'(1000)) / perf_cacheable_req_count,
				perf_flush_count);
			$display("[PERF-DCACHE] mem_req=%0d mem_resp=%0d write_through=%0d lines=%0d line_bytes=%0d",
				perf_mem_req_count,
				perf_mem_resp_count,
				perf_write_through_count,
				LINE_COUNT,
				LINE_BYTES);
			$display("[PERF-DCACHE-WB] enabled=%0d store_hit=%0d evict=%0d words=%0d req_wait=%0d",
				WRITE_BACK,
				perf_write_back_store_hit_count,
				perf_write_back_evict_count,
				perf_write_back_word_count,
				perf_write_back_req_wait_cycle);
			$display("[PERF-DCACHE-WB-FLUSH] clean=%0d dirty=%0d scan=%0d dirty_lines=%0d words=%0d req_wait=%0d",
				perf_wb_flush_clean_count,
				perf_wb_flush_dirty_count,
				perf_wb_flush_scan_cycle,
				perf_wb_flush_dirty_line_count,
				perf_wb_flush_word_count,
				perf_wb_flush_req_wait_cycle);
			$display("[PERF-DCACHE-MIX] load_hit=%0d load_miss=%0d store_hit=%0d store_miss=%0d",
				perf_load_hit_count,
				perf_load_miss_count,
				perf_store_hit_count,
				perf_store_miss_count);
			$display("[PERF-STOREBUF] enq=%0d drain=%0d full_stall=%0d depth=%0d pending=%0d outstanding=%0d",
				perf_store_buffer_enq_count,
				perf_store_buffer_drain_count,
				perf_store_buffer_full_stall_count,
				STORE_BUFFER_DEPTH,
				store_buffer_count,
				1'b0);
			$display("[PERF-STOREBUF-OCC] empty=%0d one=%0d two=%0d almost_full=%0d full=%0d",
				perf_store_buffer_occ_empty_cycle,
				perf_store_buffer_occ_one_cycle,
				perf_store_buffer_occ_two_cycle,
				perf_store_buffer_occ_almost_full_cycle,
				perf_store_buffer_occ_full_cycle);
			$display("[PERF-STOREBUF-DRAIN] urgent_active=%0d urgent_wait=%0d low_active=%0d low_wait=%0d",
				perf_store_drain_urgent_active_cycle,
				perf_store_drain_urgent_wait_cycle,
				perf_store_drain_low_active_cycle,
				perf_store_drain_low_wait_cycle);
			$display("[PERF-STOREBUF-COMBINE] candidate=%0d tail_word=%0d tail_disjoint=%0d any_word=%0d any_line=%0d",
				perf_store_combine_candidate_count,
				perf_store_combine_tail_word_count,
				perf_store_combine_tail_disjoint_count,
				perf_store_combine_any_word_count,
				perf_store_combine_any_line_count);
			$display("[PERF-STOREBUF-LOAD] bypass=%0d wait=%0d",
				perf_store_buffer_load_bypass_count,
				perf_store_buffer_load_wait_count);
			$display("[PERF-DSTALL] load_miss=%0d uncached=%0d storebuf_full=%0d storebuf_dep=%0d",
				perf_load_miss_stall_cycle,
				perf_uncached_stall_cycle,
				perf_store_buffer_full_stall_count,
				perf_store_buffer_load_wait_count);
			$display("[PERF-DCACHE-CPUWAIT] busy=%0d rsp_pending=%0d store_full=%0d load_overlap=%0d load_store_empty=%0d uncached_store_empty=%0d other=%0d",
				perf_cpu_wait_busy_cycle,
				perf_cpu_wait_rsp_pending_cycle,
				perf_cpu_wait_store_full_cycle,
				perf_cpu_wait_load_overlap_cycle,
				perf_cpu_wait_load_store_empty_cycle,
				perf_cpu_wait_uncached_store_empty_cycle,
				perf_cpu_wait_other_cycle);
			$display("[PERF-DCACHE-MEMWAIT] fill_req=%0d fill_rsp=%0d bypass_req=%0d bypass_rsp=%0d drain_active=%0d drain_req_wait=%0d",
				perf_load_fill_req_wait_cycle,
				perf_load_fill_rsp_wait_cycle,
				perf_bypass_req_wait_cycle,
				perf_bypass_rsp_wait_cycle,
				perf_store_drain_active_cycle,
				perf_store_drain_req_wait_cycle);
			$display("[PERF-DCACHE-RSP] hit_load=%0d fill_critical=%0d bypass_load=%0d bypass_amo=%0d",
				perf_response_cache_hit_load_count,
				perf_response_fill_critical_count,
				perf_response_bypass_load_count,
				perf_response_bypass_amo_count);
			$display("[PERF-DCACHE-FAST] hit_load=%0d",
				perf_fast_load_hit_count);
		end
	end

endmodule : dcache
