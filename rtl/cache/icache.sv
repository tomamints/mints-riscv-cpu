import eei::*;

module icache #(
	parameter int unsigned LINE_COUNT = 256
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
	localparam int unsigned TAG_WIDTH = XLEN - 3 - INDEX_WIDTH;

	typedef enum logic [2:0] {
		Idle,
		MissReq,
		MissWait,
		MissDiscard,
		Response
	} State;

	State state;

	logic [LINE_COUNT-1:0] valid;
	logic [TAG_WIDTH-1:0] tags [LINE_COUNT];
	UInt64 data [LINE_COUNT];

	Addr pending_addr;
	logic pending_cacheable;
	logic [INDEX_WIDTH-1:0] pending_index;
	logic [TAG_WIDTH-1:0] pending_tag;

	logic [INDEX_WIDTH-1:0] req_index;
	logic [TAG_WIDTH-1:0] req_tag;
	Addr req_line_addr;
	logic req_cacheable;
	logic cache_hit;
	UInt64 perf_cacheable_req_count;

	UInt64 perf_req_count;
	UInt64 perf_hit_count;
	UInt64 perf_miss_count;
	UInt64 perf_uncached_count;
	UInt64 perf_mem_req_count;
	UInt64 perf_mem_resp_count;
	UInt64 perf_flush_count;

	assign req_line_addr = {req_addr[XLEN-1:3], 3'b000};
	assign req_index = req_addr[3 +: INDEX_WIDTH];
	assign req_tag = req_addr[XLEN-1 -: TAG_WIDTH];
	localparam Addr MMAP_RAM_END = MMAP_RAM_BEGIN + (Addr'(1) << RAM_ADDR_WIDTH);

	assign req_cacheable =
		(req_addr >= MMAP_RAM_BEGIN && req_addr < MMAP_RAM_END) ||
		(req_addr >= MMAP_ROM_BEGIN && req_addr <= MMAP_ROM_END);
	assign cache_hit = req_cacheable && valid[req_index] && tags[req_index] == req_tag;

	initial begin
		if (LINE_COUNT < 2 || (LINE_COUNT & (LINE_COUNT - 1)) != 0) begin
			$fatal(1, "ICACHE LINE_COUNT must be a power of two and at least 2");
		end
	end

	assign req_ready = state == Idle;
	assign mem_valid = state == MissReq;
	assign mem_addr = pending_addr;

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Idle;
			rsp_valid <= 1'b0;
			rsp_data <= '0;
			pending_addr <= '0;
			pending_cacheable <= 1'b0;
			pending_index <= '0;
			pending_tag <= '0;
			perf_req_count <= '0;
			perf_cacheable_req_count <= '0;
			perf_hit_count <= '0;
			perf_miss_count <= '0;
			perf_uncached_count <= '0;
			perf_mem_req_count <= '0;
			perf_mem_resp_count <= '0;
			perf_flush_count <= '0;
			for (int unsigned i = 0; i < LINE_COUNT; i++) begin
				valid[i] <= 1'b0;
			end
		end else begin
			if (invalidate) begin
				for (int unsigned i = 0; i < LINE_COUNT; i++) begin
					valid[i] <= 1'b0;
				end
				rsp_valid <= 1'b0;
				perf_flush_count <= perf_flush_count + UInt64'(1);
				unique case (state)
					MissReq: state <= mem_ready ? MissDiscard : Idle;
					MissWait: state <= MissDiscard;
					default: state <= Idle;
				endcase
			end else if (cancel) begin
				rsp_valid <= 1'b0;
				unique case (state)
					MissReq: state <= mem_ready ? MissDiscard : Idle;
					MissWait: state <= MissDiscard;
					default: state <= Idle;
				endcase
			end else begin
				if (rsp_valid && rsp_ready) begin
					rsp_valid <= 1'b0;
				end

				unique case (state)
					Idle: begin
						if (req_valid && req_ready) begin
							perf_req_count <= perf_req_count + UInt64'(1);
							if (req_cacheable) begin
								perf_cacheable_req_count <= perf_cacheable_req_count + UInt64'(1);
							end
							if (cache_hit) begin
								rsp_data <= data[req_index];
								rsp_valid <= 1'b1;
								perf_hit_count <= perf_hit_count + UInt64'(1);
								state <= Response;
							end else begin
								pending_addr <= req_line_addr;
								pending_cacheable <= req_cacheable;
								pending_index <= req_index;
								pending_tag <= req_tag;
								perf_miss_count <= perf_miss_count + UInt64'(1);
								if (!req_cacheable) begin
									perf_uncached_count <= perf_uncached_count + UInt64'(1);
								end
								state <= MissReq;
							end
						end
					end

					MissReq: begin
						if (mem_ready) begin
							perf_mem_req_count <= perf_mem_req_count + UInt64'(1);
							state <= MissWait;
						end
					end

					MissWait: begin
						if (mem_rvalid) begin
							perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
							if (pending_cacheable) begin
								valid[pending_index] <= 1'b1;
								tags[pending_index] <= pending_tag;
								data[pending_index] <= mem_rdata;
							end
							rsp_data <= mem_rdata;
							rsp_valid <= 1'b1;
							state <= Response;
						end
					end

					MissDiscard: begin
						if (mem_rvalid) begin
							perf_mem_resp_count <= perf_mem_resp_count + UInt64'(1);
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
			$display("[PERF-ICACHE] req=%0d cacheable=%0d hit=%0d miss=%0d uncached=%0d hit_rate_x1000=%0d flush=%0d",
				perf_req_count,
				perf_cacheable_req_count,
				perf_hit_count,
				perf_miss_count,
				perf_uncached_count,
				(perf_cacheable_req_count == 0) ? UInt64'(0) : (perf_hit_count * UInt64'(1000)) / perf_cacheable_req_count,
				perf_flush_count);
			$display("[PERF-ICACHE] mem_req=%0d mem_resp=%0d lines=%0d line_bytes=8",
				perf_mem_req_count,
				perf_mem_resp_count,
				LINE_COUNT);
		end
	end

endmodule : icache
