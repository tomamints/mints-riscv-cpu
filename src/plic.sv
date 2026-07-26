import eei::*;

module plic (
	input  logic clk,
	input  logic rst,
	Membus.slave membus,
	input  logic [PLIC_NUM_SOURCES:0] source_irq,
	output logic meip,
	output logic seip
);

	logic [2:0] irq_priority [PLIC_NUM_SOURCES:0];
	logic [PLIC_NUM_SOURCES:0] pending;
	logic [PLIC_NUM_SOURCES:0] enable_m;
	logic [PLIC_NUM_SOURCES:0] enable_s;
	logic [2:0] threshold_m;
	logic [2:0] threshold_s;

	localparam logic [5:0] PLIC_LAST_IRQ = 6'(PLIC_NUM_SOURCES);
	localparam Addr PLIC_ENABLE_CONTEXT_STRIDE = Addr'('h80);

	function automatic logic [31:0] word_from_bus(
		input logic [MEMBUS_DATA_WIDTH-1:0] wdata,
		input Addr addr
	);
		word_from_bus = addr[2] ? wdata[63:32] : wdata[31:0];
	endfunction

	function automatic logic [MEMBUS_DATA_WIDTH-1:0] word_to_bus(
		input logic [31:0] value,
		input Addr addr
	);
		word_to_bus = '0;
		if (addr[2]) begin
			word_to_bus[63:32] = value;
		end else begin
			word_to_bus[31:0] = value;
		end
	endfunction

	function automatic logic [PLIC_NUM_SOURCES:0] enable_from_word(input logic [31:0] value);
		enable_from_word = '0;
		enable_from_word[31:1] = value[31:1];
	endfunction

	function automatic logic [5:0] select_irq(
		input logic [PLIC_NUM_SOURCES:0] enable,
		input logic [2:0] threshold
	);
		logic [5:0] best_irq;
		logic [2:0] best_priority;
		best_irq = '0;
		best_priority = threshold;

		for (int i = 1; i <= PLIC_NUM_SOURCES; i++) begin
			if (pending[i] && enable[i] && (irq_priority[i] > best_priority)) begin
				best_irq = 6'(i);
				best_priority = irq_priority[i];
			end
		end

		return best_irq;
	endfunction

	function automatic logic [31:0] read_reg(input Addr addr);
		logic [31:0] value;
		logic [5:0] irq_index;
		value = '0;
		irq_index = addr[7:2];

		if (addr < PLIC_PENDING_BASE) begin
			if (irq_index <= PLIC_LAST_IRQ) begin
				value = {29'b0, irq_priority[irq_index]};
			end
		end else if (addr == PLIC_PENDING_BASE) begin
			value = pending[31:0];
		end else if (addr == PLIC_PENDING_BASE + 4) begin
			value = {31'b0, pending[32]};
		end else if (addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_M) * PLIC_ENABLE_CONTEXT_STRIDE) begin
			value = enable_m[31:0];
		end else if (addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_S) * PLIC_ENABLE_CONTEXT_STRIDE) begin
			value = enable_s[31:0];
		end else if (addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_M) * PLIC_ENABLE_CONTEXT_STRIDE + 4) begin
			value = {31'b0, enable_m[32]};
		end else if (addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_S) * PLIC_ENABLE_CONTEXT_STRIDE + 4) begin
			value = {31'b0, enable_s[32]};
		end else if (addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_M * PLIC_CONTEXT_STRIDE)) begin
			value = {29'b0, threshold_m};
		end else if (addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_M * PLIC_CONTEXT_STRIDE) + 4) begin
			value = {26'b0, select_irq(enable_m, threshold_m)};
		end else if (addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_S * PLIC_CONTEXT_STRIDE)) begin
			value = {29'b0, threshold_s};
		end else if (addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_S * PLIC_CONTEXT_STRIDE) + 4) begin
			value = {26'b0, select_irq(enable_s, threshold_s)};
		end

		return value;
	endfunction

	logic [5:0] selected_m;
	logic [5:0] selected_s;
	assign selected_m = select_irq(enable_m, threshold_m);
	assign selected_s = select_irq(enable_s, threshold_s);
	assign meip = selected_m != 6'd0;
	assign seip = selected_s != 6'd0;

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			membus.ready <= 1'b1;
			membus.rvalid <= 1'b0;
			membus.rdata <= '0;
			pending <= '0;
			enable_m <= '0;
			enable_s <= '0;
			threshold_m <= '0;
			threshold_s <= '0;
			for (int i = 0; i <= PLIC_NUM_SOURCES; i++) begin
				irq_priority[i] <= '0;
			end
		end else begin
			logic [31:0] wword;
			logic [5:0] irq_index;
			logic [5:0] claim_m;
			logic [5:0] claim_s;

			membus.ready <= 1'b1;
			membus.rvalid <= membus.valid;
			membus.rdata <= membus.valid ? word_to_bus(read_reg(membus.addr), membus.addr) : '0;
			pending <= pending | source_irq;
			pending[0] <= 1'b0;

			wword = word_from_bus(membus.wdata, membus.addr);
			irq_index = membus.addr[7:2];
			claim_m = select_irq(enable_m, threshold_m);
			claim_s = select_irq(enable_s, threshold_s);

			if (membus.valid) begin
				if ($test$plusargs("TRACE_PLIC")) begin
					$display("[PLIC] %s addr=%h wdata=%h rdata=%h pending=%h enable_m=%h enable_s=%h meip=%b seip=%b",
						membus.wen ? "W" : "R",
						membus.addr,
						wword,
						read_reg(membus.addr),
						pending,
						enable_m,
						enable_s,
						meip,
						seip);
				end
				if (membus.wen) begin
					if (membus.addr < PLIC_PENDING_BASE) begin
						if (irq_index >= 6'd1 && irq_index <= PLIC_LAST_IRQ) begin
							irq_priority[irq_index] <= wword[2:0];
						end
					end else if (membus.addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_M) * PLIC_ENABLE_CONTEXT_STRIDE) begin
						enable_m <= enable_from_word(wword);
					end else if (membus.addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_S) * PLIC_ENABLE_CONTEXT_STRIDE) begin
						enable_s <= enable_from_word(wword);
					end else if (membus.addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_M) * PLIC_ENABLE_CONTEXT_STRIDE + 4) begin
						enable_m[32] <= wword[0];
					end else if (membus.addr == PLIC_ENABLE_BASE + Addr'(PLIC_CONTEXT_S) * PLIC_ENABLE_CONTEXT_STRIDE + 4) begin
						enable_s[32] <= wword[0];
					end else if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_M * PLIC_CONTEXT_STRIDE)) begin
						threshold_m <= wword[2:0];
					end else if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_M * PLIC_CONTEXT_STRIDE) + 4) begin
						if (wword[5:0] <= PLIC_LAST_IRQ) begin
							pending[wword[5:0]] <= 1'b0;
						end
					end else if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_S * PLIC_CONTEXT_STRIDE)) begin
						threshold_s <= wword[2:0];
					end else if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_S * PLIC_CONTEXT_STRIDE) + 4) begin
						if (wword[5:0] <= PLIC_LAST_IRQ) begin
							pending[wword[5:0]] <= 1'b0;
						end
					end
				end else begin
					if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_M * PLIC_CONTEXT_STRIDE) + 4 && claim_m != 6'd0) begin
						pending[claim_m] <= 1'b0;
					end else if (membus.addr == PLIC_CONTEXT_BASE + Addr'(PLIC_CONTEXT_S * PLIC_CONTEXT_STRIDE) + 4 && claim_s != 6'd0) begin
						pending[claim_s] <= 1'b0;
					end
				end
			end
		end
	end

endmodule : plic
