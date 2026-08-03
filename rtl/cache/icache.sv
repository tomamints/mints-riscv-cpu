import eei::*;

module icache #(
	parameter int unsigned LINE_COUNT = 128
) (
	input logic clk,
	input logic rst,
	input logic cancel,
	input logic invalidate,

	input logic req_valid,
	output logic req_ready,
	input Addr req_addr,

	output logic rsp_valid,
	input logic rsp_ready,
	output UInt64 rsp_data,

	output logic mem_valid,
	input logic mem_ready,
	output Addr mem_addr,
	input logic mem_rvalid,
	input UInt64 mem_rdata
);

	localparam int unsigned INDEX_WIDTH = LINE_COUNT <= 1 ? 1 : $clog2(LINE_COUNT);
	localparam int unsigned LINE_BYTES = 32;
	localparam int unsigned LINE_OFFSET_WIDTH = 5;
	localparam int unsigned WORDS_PER_LINE = LINE_BYTES / 8;
	localparam int unsigned WORD_OFFSET_WIDTH = $clog2(WORDS_PER_LINE);
	localparam int unsigned FILL_COUNT_WIDTH = $clog2(WORDS_PER_LINE + 1);
	localparam int unsigned TAG_WIDTH = XLEN - LINE_OFFSET_WIDTH - INDEX_WIDTH;
	localparam Addr MMAP_RAM_END = MMAP_RAM_BEGIN + (Addr'(1) << RAM_ADDR_WIDTH);

	typedef enum logic [2:0] {
		Idle,
		FillReq,
		FillWait,
		Response,
		InvalidateWait
	} State;

	State state;

	logic [LINE_COUNT-1:0] valid;
	logic [TAG_WIDTH-1:0] tags [LINE_COUNT];
	UInt64 data [LINE_COUNT][WORDS_PER_LINE];

	Addr fill_line_addr;
	logic fill_active;
	logic fill_cacheable;
	logic fill_uncached;
	logic fill_allocate;
	logic fill_cpu_waiting;
	logic [INDEX_WIDTH-1:0] fill_index;
	logic [TAG_WIDTH-1:0] fill_tag;
	logic [WORD_OFFSET_WIDTH-1:0] fill_next_word;
	logic [WORD_OFFSET_WIDTH-1:0] fill_response_word;
	logic [FILL_COUNT_WIDTH-1:0] fill_count;
	logic [WORDS_PER_LINE-1:0] fill_word_valid;
	UInt64 fill_data [WORDS_PER_LINE];

	logic [INDEX_WIDTH-1:0] req_index;
	logic [TAG_WIDTH-1:0] req_tag;
	logic [WORD_OFFSET_WIDTH-1:0] req_word_offset;
	Addr req_line_addr;
	Addr req_beat_addr;
	logic req_cacheable;
	logic cache_hit;
	logic fill_line_match;
	logic fill_hit;
	logic fill_response_now;
	logic mem_will_respond_cpu;
	logic rsp_remains;

	UInt64 perf_req_count;
	UInt64 perf_cacheable_req_count;
	UInt64 perf_hit_count;
	UInt64 perf_fill_hit_count;
	UInt64 perf_miss_count;
	UInt64 perf_uncached_count;
	UInt64 perf_mem_req_count;
	UInt64 perf_mem_resp_count;
	UInt64 perf_flush_count;
	UInt64 perf_early_rsp_count;
	UInt64 perf_demand_miss_stall_cycle;

	assign req_line_addr = {req_addr[XLEN-1:LINE_OFFSET_WIDTH], {LINE_OFFSET_WIDTH{1'b0}}};
	assign req_beat_addr = {req_addr[XLEN-1:3], 3'b000};
	assign req_index = req_addr[LINE_OFFSET_WIDTH +: INDEX_WIDTH];
	assign req_tag = req_addr[XLEN-1 -: TAG_WIDTH];
	assign req_word_offset = req_addr[3 +: WORD_OFFSET_WIDTH];
	assign req_cacheable =
		(req_addr >= MMAP_RAM_BEGIN && req_addr < MMAP_RAM_END) ||
		(req_addr >= MMAP_ROM_BEGIN && req_addr <= MMAP_ROM_END);
	assign cache_hit = req_cacheable && valid[req_index] && tags[req_index] == req_tag;
	assign fill_line_match =
		fill_active &&
		fill_allocate &&
		req_cacheable &&
		fill_cacheable &&
		req_line_addr == fill_line_addr;
	assign fill_hit = fill_line_match && fill_word_valid[req_word_offset];
	assign fill_response_now =
		fill_cpu_waiting &&
		!fill_uncached &&
		fill_next_word == fill_response_word &&
		!cancel;
	assign mem_will_respond_cpu =
		state == FillWait &&
		mem_rvalid &&
		(
			(fill_uncached && fill_cpu_waiting && !cancel) ||
			fill_response_now
		);
	assign rsp_remains = (rsp_valid && !rsp_ready) || fill_response_now;

	assign req_ready =
		!cancel &&
		!invalidate &&
		(
			(state == Idle) ||
			(
				(state == FillReq || state == FillWait) &&
				fill_hit &&
				!rsp_valid &&
				!mem_will_respond_cpu
			)
		);
	assign mem_valid = state == FillReq;
	// The backing memory returns read data after a request accept, not in the
	// same cycle as mem_valid && mem_ready.
	assign mem_addr = fill_uncached ?
		{fill_line_addr[XLEN-1:3], 3'b000} :
		(fill_line_addr + (Addr'(fill_next_word) << 3));

	initial begin
		if (LINE_COUNT < 2 || (LINE_COUNT & (LINE_COUNT - 1)) != 0) begin
			$fatal(1, "ICACHE LINE_COUNT must be a power of two and at least 2");
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Idle;
			rsp_valid <= 1'b0;
			rsp_data <= '0;
			fill_line_addr <= '0;
			fill_active <= 1'b0;
			fill_cacheable <= 1'b0;
			fill_uncached <= 1'b0;
			fill_allocate <= 1'b0;
			fill_cpu_waiting <= 1'b0;
			fill_index <= '0;
			fill_tag <= '0;
			fill_next_word <= '0;
			fill_response_word <= '0;
			fill_count <= '0;
			fill_word_valid <= '0;
			perf_req_count <= '0;
			perf_cacheable_req_count <= '0;
			perf_hit_count <= '0;
			perf_fill_hit_count <= '0;
			perf_miss_count <= '0;
			perf_uncached_count <= '0;
			perf_mem_req_count <= '0;
			perf_mem_resp_count <= '0;
			perf_flush_count <= '0;
			perf_early_rsp_count <= '0;
			perf_demand_miss_stall_cycle <= '0;
			for (int unsigned i = 0; i < LINE_COUNT; i++) begin
				valid[i] <= 1'b0;
			end
		end else begin
			if (!cancel &&
				(state == FillReq || state == FillWait) &&
				fill_cpu_waiting &&
				!mem_will_respond_cpu) begin
				perf_demand_miss_stall_cycle <= perf_demand_miss_stall_cycle + UInt64'(1);
			end

			if (rsp_valid && rsp_ready) begin
				rsp_valid <= 1'b0;
			end

			if (cancel) begin
				rsp_valid <= 1'b0;
				fill_cpu_waiting <= 1'b0;
			end

			if (invalidate) begin
				for (int unsigned i = 0; i < LINE_COUNT; i++) begin
					valid[i] <= 1'b0;
				end
				rsp_valid <= 1'b0;
				fill_allocate <= 1'b0;
				fill_cpu_waiting <= 1'b0;
				fill_word_valid <= '0;
				perf_flush_count <= perf_flush_count + UInt64'(1);
				unique case (state)
					FillReq: begin
						if (mem_ready) begin
							perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
							state <= InvalidateWait;
						end else begin
							fill_active <= 1'b0;
							state <= Idle;
						end
					end

					FillWait: begin
						if (mem_rvalid) begin
							perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
							fill_active <= 1'b0;
							state <= Idle;
						end else begin
							state <= InvalidateWait;
						end
					end

					default: begin
						fill_active <= 1'b0;
						state <= Idle;
					end
				endcase
			end else begin
				unique case (state)
					Idle: begin
						if (req_valid && req_ready) begin
							perf_req_count <= perf_req_count + UInt64'(1);
							if (req_cacheable) begin
								perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
							end

							if (cache_hit) begin
								rsp_data <= data[req_index][req_word_offset];
								rsp_valid <= 1'b1;
								perf_hit_count <= perf_hit_count + UInt64'(1);
								state <= Response;
							end else begin
								fill_line_addr <= req_cacheable ? req_line_addr : req_beat_addr;
								fill_active <= 1'b1;
								fill_cacheable <= req_cacheable;
								fill_uncached <= !req_cacheable;
								fill_allocate <= req_cacheable;
								fill_cpu_waiting <= 1'b1;
								fill_index <= req_index;
								fill_tag <= req_tag;
								fill_next_word <= req_cacheable ? req_word_offset : '0;
								fill_response_word <= req_word_offset;
								fill_count <= '0;
								fill_word_valid <= '0;
								if (req_cacheable) begin
									perf_miss_count <= perf_miss_count + UInt64'(1);
								end else begin
									perf_uncached_count <= perf_uncached_count + UInt64'(1);
								end
								state <= FillReq;
							end
						end
					end

					FillReq: begin
						if (req_valid && req_ready && fill_hit) begin
							perf_req_count <= perf_req_count + UInt64'(1);
							perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
							perf_fill_hit_count <= perf_fill_hit_count + UInt64'(1);
							rsp_data <= fill_data[req_word_offset];
							rsp_valid <= 1'b1;
						end

						if (mem_ready) begin
							perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
							state <= FillWait;
						end
					end

					FillWait: begin
						if (req_valid && req_ready && fill_hit) begin
							perf_req_count <= perf_req_count + UInt64'(1);
							perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
							perf_fill_hit_count <= perf_fill_hit_count + UInt64'(1);
							rsp_data <= fill_data[req_word_offset];
							rsp_valid <= 1'b1;
						end

						if (mem_rvalid) begin
							perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);

							if (fill_uncached) begin
								if (fill_cpu_waiting && !cancel) begin
									rsp_data <= mem_rdata;
									rsp_valid <= 1'b1;
								end
								fill_cpu_waiting <= 1'b0;
								fill_active <= 1'b0;
								state <= (fill_cpu_waiting && !cancel) ? Response : Idle;
							end else begin
								fill_data[fill_next_word] <= mem_rdata;
								fill_word_valid[fill_next_word] <= 1'b1;

								if (fill_response_now) begin
									rsp_data <= mem_rdata;
									rsp_valid <= 1'b1;
									fill_cpu_waiting <= 1'b0;
									perf_early_rsp_count <= perf_early_rsp_count + UInt64'(1);
								end

								if (fill_count == FILL_COUNT_WIDTH'(WORDS_PER_LINE - 1)) begin
									if (fill_allocate) begin
										valid[fill_index] <= 1'b1;
										tags[fill_index] <= fill_tag;
										for (int unsigned i = 0; i < WORDS_PER_LINE; i++) begin
											data[fill_index][i] <= (WORD_OFFSET_WIDTH'(i) == fill_next_word) ? mem_rdata : fill_data[i];
										end
									end
									fill_active <= 1'b0;
									state <= rsp_remains ? Response : Idle;
								end else begin
									fill_next_word <= fill_next_word + WORD_OFFSET_WIDTH'(1);
									fill_count <= fill_count + FILL_COUNT_WIDTH'(1);
									state <= FillReq;
								end
							end
						end
					end

					InvalidateWait: begin
						if (state == InvalidateWait && mem_rvalid) begin
							perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
							fill_active <= 1'b0;
							fill_cpu_waiting <= 1'b0;
							fill_word_valid <= '0;
							state <= Idle;
						end
					end

					Response: begin
						if (!rsp_valid || rsp_ready) begin
							state <= Idle;
						end
					end

					default: state <= Idle;
				endcase
			end
		end
	end

	final begin
		if ($test$plusargs("PERF_SUMMARY")) begin
			$display("[PERF-ICACHE] req=%0d cacheable=%0d hit=%0d fill_hit=%0d miss=%0d uncached=%0d hit_rate_x1000=%0d flush=%0d",
				perf_req_count,
				perf_cacheable_req_count,
				perf_hit_count,
				perf_fill_hit_count,
				perf_miss_count,
				perf_uncached_count,
				(perf_cacheable_req_count == 0) ? UInt64'(0) : ((perf_hit_count + perf_fill_hit_count) * UInt64'(1000)) / perf_cacheable_req_count,
				perf_flush_count);
			$display("[PERF-ICACHE] mem_req=%0d mem_resp=%0d early_rsp=%0d lines=%0d line_bytes=%0d",
				perf_mem_req_count,
				perf_mem_resp_count,
				perf_early_rsp_count,
				LINE_COUNT,
				LINE_BYTES);
			$display("[PERF-ICACHE-STALL] demand_miss=%0d",
				perf_demand_miss_stall_cycle);
		end
	end

endmodule : icache
