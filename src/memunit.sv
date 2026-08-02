import eei::*;
import corectrl::*;

module memunit (
	input logic clk,
	input logic rst,
	input logic valid,
	input logic is_new,
	input InstCtrl ctrl,
	input PrivMode priv_mode,
	input UIntX satp,
	input logic sstatus_sum,
	input logic sstatus_mxr,
	input logic translation_flush,
	input Addr addr,
	input UIntX rs2,
	output UIntX rdata,
	output logic stall,
	output ExceptionInfo expt,
	core_data_if.master membus
	);

	typedef enum logic[2:0] {
		Init,
		TranslateWait,
		AccessWaitReady,
		AccessWaitValid,
		SplitAccessWaitReady,
		SplitAccessWaitValid,
		DiscardWaitValid,
		Fault
	} State;

	typedef enum logic[1:0] {
		MemOwnerNone,
		MemOwnerTranslation,
		MemOwnerData
	} MemOwner;

	State state;
	MemOwner mem_owner;

	logic req_wen;
	Addr req_vaddr;
	Addr req_paddr;
	UIntX req_rs2;
	logic [MEMBUS_DATA_WIDTH-1:0] req_wdata;
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] req_wmask;
	logic req_is_amo;
	AMOOp req_amoop;
		logic req_aq;
		logic req_rl;
		logic [2:0] req_funct3;
		logic [2:0] req_offset;
		logic [3:0] req_size;
		logic req_crosses_word;
		logic [MEMBUS_DATA_WIDTH-1:0] req_first_rdata;
		UIntX load_result;

		Sv39Fault fault_detail;
		CsrCause fault_cause;
		Addr fault_value;

		logic satp_sv39;
		logic need_translate;
		logic translation_req_valid;
	logic translation_req_ready;
	logic translation_rsp_valid;
	logic translation_rsp_ready;
	logic translation_fault;
	Sv39Fault translation_fault_detail;
	CsrCause translation_fault_cause;
	Addr translation_pa;
	Addr translation_fault_value;
	logic translation_mem_valid;
	Addr translation_mem_addr;
		logic translation_mem_rvalid;
		logic data_mem_rvalid;
		PmpAccessType translation_access_type;
		logic translation_mem_fire;
		logic first_data_mem_fire;
		logic split_data_mem_fire;
		logic data_read_mem_fire;
		logic response_will_be_outstanding;

		localparam Addr MMAP_RAM_END = MMAP_RAM_BEGIN + (Addr'(1) << RAM_ADDR_WIDTH);

	function automatic logic [3:0] access_size_bytes(input logic [1:0] funct3_lo);
		unique case (funct3_lo)
			2'b00: access_size_bytes = 4'd1;
			2'b01: access_size_bytes = 4'd2;
			2'b10: access_size_bytes = 4'd4;
			2'b11: access_size_bytes = 4'd8;
			default: access_size_bytes = 4'd1;
		endcase
	endfunction

		function automatic logic [7:0] byte_mask(input logic [3:0] bytes);
			unique case (bytes)
				4'd0: byte_mask = 8'h00;
				4'd1: byte_mask = 8'h01;
				4'd2: byte_mask = 8'h03;
			4'd3: byte_mask = 8'h07;
			4'd4: byte_mask = 8'h0f;
			4'd5: byte_mask = 8'h1f;
				4'd6: byte_mask = 8'h3f;
				4'd7: byte_mask = 8'h7f;
				default: byte_mask = 8'hff;
			endcase
		endfunction

		function automatic logic access_misaligned(
			input logic [2:0] funct3,
			input Addr access_addr
		);
			unique case (funct3[1:0])
				2'b00: access_misaligned = 1'b0;
				2'b01: access_misaligned = access_addr[0] != 1'b0;
				2'b10: access_misaligned = access_addr[1:0] != 2'b00;
				2'b11: access_misaligned = access_addr[2:0] != 3'b000;
				default: access_misaligned = 1'b0;
			endcase
		endfunction

		function automatic logic amo_misaligned(
			input logic [2:0] funct3,
			input Addr access_addr
		);
			unique case (funct3)
				3'b010: amo_misaligned = access_addr[1:0] != 2'b00;
				3'b011: amo_misaligned = access_addr[2:0] != 3'b000;
				default: amo_misaligned = 1'b1;
			endcase
		endfunction

		function automatic logic is_normal_memory(input Addr paddr);
			return (paddr >= MMAP_RAM_BEGIN && paddr < MMAP_RAM_END) ||
				(paddr >= MMAP_ROM_BEGIN && paddr <= MMAP_ROM_END);
		endfunction

		function automatic UIntX extract_load_data(
			input logic [127:0] data,
			input logic [2:0] offset,
			input logic [2:0] funct3
		);
		logic [127:0] shifted;
		shifted = data >> {offset, 3'b000};
		unique case (funct3[1:0])
			2'b00: extract_load_data = {{(XLEN-8){~funct3[2] & shifted[7]}}, shifted[7:0]};
			2'b01: extract_load_data = {{(XLEN-16){~funct3[2] & shifted[15]}}, shifted[15:0]};
			2'b10: extract_load_data = {{(XLEN-32){~funct3[2] & shifted[31]}}, shifted[31:0]};
			2'b11: extract_load_data = shifted[63:0];
			default: extract_load_data = '0;
		endcase
	endfunction

	function automatic logic [MEMBUS_DATA_WIDTH-1:0] split_store_second_wdata(
		input UIntX data,
		input logic [2:0] offset
	);
		logic [5:0] shift_bits;
		shift_bits = (6'd8 - {3'b000, offset}) << 3;
		split_store_second_wdata = data >> shift_bits;
		endfunction

		assign satp_sv39 = satp[63:60] == 4'd8;
		assign need_translate = satp_sv39 && (priv_mode != M);
		assign translation_req_valid = valid && state == TranslateWait;
		assign translation_rsp_ready = valid && state == TranslateWait;
		assign translation_access_type = (req_wen || req_is_amo) ? PMP_ACCESS_WRITE : PMP_ACCESS_READ;
		assign translation_mem_rvalid = membus.rvalid && mem_owner == MemOwnerTranslation;
		assign data_mem_rvalid = membus.rvalid && mem_owner == MemOwnerData;
		assign translation_mem_fire = valid && translation_mem_valid && membus.ready;
		assign first_data_mem_fire = valid && state == AccessWaitReady && membus.ready;
		assign split_data_mem_fire = valid && state == SplitAccessWaitReady && membus.ready;
		assign data_read_mem_fire =
			(first_data_mem_fire && (!req_wen || req_is_amo)) ||
			(split_data_mem_fire && !req_wen);
		assign response_will_be_outstanding =
			(mem_owner != MemOwnerNone && !membus.rvalid) ||
			translation_mem_fire ||
			data_read_mem_fire;

	data_translation translation (
		.clk(clk),
		.rst(rst),
		.flush(!valid),
		.tlb_flush(translation_flush),
		.req_valid(translation_req_valid),
		.req_ready(translation_req_ready),
		.req_va(req_vaddr),
		.req_priv_mode(priv_mode),
		.req_access_type(translation_access_type),
		.req_sum(sstatus_sum),
		.req_mxr(sstatus_mxr),
		.satp(satp),
		.rsp_valid(translation_rsp_valid),
		.rsp_ready(translation_rsp_ready),
		.rsp_pa(translation_pa),
		.rsp_fault(translation_fault),
		.rsp_fault_detail(translation_fault_detail),
		.rsp_fault_cause(translation_fault_cause),
		.rsp_fault_value(translation_fault_value),
		.ptw_mem_valid(translation_mem_valid),
		.ptw_mem_addr(translation_mem_addr),
		.ptw_mem_ready(membus.ready),
		.ptw_mem_rvalid(translation_mem_rvalid),
		.ptw_mem_error(1'b0),
		.ptw_mem_rdata(membus.rdata)
	);

		always_comb begin
			membus.valid  = 1'b0;
			membus.addr   = '0;
			membus.wen    = 1'b0;
			membus.wdata  = '0;
		membus.wmask  = '0;
		membus.is_amo = 1'b0;
		membus.amoop  = AMOOp'(0);
		membus.aq     = 1'b0;
		membus.rl     = 1'b0;
		membus.funct3 = 3'b011;

			if (valid && translation_mem_valid) begin
				membus.valid = 1'b1;
				membus.addr = translation_mem_addr;
			end else if (valid && state == AccessWaitReady) begin
				membus.valid  = 1'b1;
				membus.addr   = req_paddr;
			membus.wen    = req_wen;
			membus.wdata  = req_wdata;
			membus.wmask  = req_wmask;
			membus.is_amo = req_is_amo;
			membus.amoop  = req_amoop;
			membus.aq     = req_aq;
			membus.rl     = req_rl;
			membus.funct3 = req_funct3;
			end else if (valid && state == SplitAccessWaitReady) begin
				membus.valid  = 1'b1;
				membus.addr   = {req_paddr[XLEN-1:3], 3'b000} + Addr'(8);
			membus.wen    = req_wen;
			membus.wdata  = req_wen ? split_store_second_wdata(req_rs2, req_offset) : '0;
			membus.wmask  = req_wen ? byte_mask(req_size - (4'd8 - {1'b0, req_offset})) : '0;
			membus.is_amo = 1'b0;
			membus.amoop  = AMOOp'(0);
			membus.aq     = 1'b0;
			membus.rl     = 1'b0;
			membus.funct3 = req_funct3;
		end

		if (req_crosses_word && state == SplitAccessWaitValid && data_mem_rvalid) begin
			rdata = extract_load_data({membus.rdata, req_first_rdata}, req_offset, req_funct3);
		end else if (req_crosses_word) begin
			rdata = load_result;
		end else begin
			rdata = extract_load_data({64'b0, membus.rdata}, req_offset, req_funct3);
		end

		case (state)
			Init:            stall = valid & (is_new && inst_is_memop(ctrl));
			TranslateWait:   stall = valid;
			AccessWaitReady: stall = valid;
			AccessWaitValid: stall = valid & (~data_mem_rvalid || req_crosses_word);
			SplitAccessWaitReady: stall = valid;
			SplitAccessWaitValid: stall = valid & ~data_mem_rvalid;
			DiscardWaitValid: stall = valid;
			Fault:           stall = 1'b0;
			default:         stall = 1'b0;
		endcase
	end

	always_comb begin
		expt = '0;
		if (state == Fault) begin
			expt.valid = 1'b1;
			expt.cause = fault_cause;
			expt.value = fault_value;
			if ($test$plusargs("TRACE_SV39")) begin
				$display("[SV39] FAULT cause=%0d detail=%0d value=%h",
					fault_cause, fault_detail, fault_value);
			end
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Init;
			mem_owner <= MemOwnerNone;
			req_wen <= 1'b0;
			req_vaddr <= '0;
			req_paddr <= '0;
			req_rs2 <= '0;
			req_wdata <= '0;
			req_wmask <= '0;
			req_is_amo <= 1'b0;
				req_amoop <= AMOOp'(0);
				req_aq <= 1'b0;
				req_rl <= 1'b0;
				req_funct3 <= '0;
				req_offset <= '0;
				req_size <= '0;
				req_crosses_word <= 1'b0;
				req_first_rdata <= '0;
				load_result <= '0;
			fault_detail <= SV39_FAULT_NONE;
			fault_cause <= CsrCause'(0);
			fault_value <= '0;
		end else begin
			if (membus.rvalid) begin
				mem_owner <= MemOwnerNone;
			end

				if (translation_mem_fire) begin
					mem_owner <= MemOwnerTranslation;
				end else if (data_read_mem_fire) begin
					mem_owner <= MemOwnerData;
				end

				if (!valid) begin
					state <= response_will_be_outstanding ? DiscardWaitValid : Init;
				end else begin
				case (state)
					Init: begin
						if (is_new & inst_is_memop(ctrl)) begin
							req_wen <= inst_is_store(ctrl);
							req_vaddr <= addr;
							req_paddr <= addr;
							req_rs2 <= rs2;
							req_wdata <= rs2 << {addr[2:0], 3'b0};
							req_is_amo <= ctrl.is_amo;
							req_amoop <= AMOOp'(ctrl.funct7[6:2]);
							req_aq <= ctrl.funct7[1];
							req_rl <= ctrl.funct7[0];
								req_funct3 <= ctrl.funct3;
								req_offset <= addr[2:0];
								req_size <= access_size_bytes(ctrl.funct3[1:0]);
								req_crosses_word <= !ctrl.is_amo &&
									(({1'b0, addr[2:0]} + access_size_bytes(ctrl.funct3[1:0])) > 4'd8);

								if (!ctrl.is_amo &&
									(({1'b0, addr[2:0]} + access_size_bytes(ctrl.funct3[1:0])) > 4'd8)) begin
									req_wmask <= byte_mask(4'd8 - {1'b0, addr[2:0]}) << addr[2:0];
								end else begin
									req_wmask <= byte_mask(access_size_bytes(ctrl.funct3[1:0])) << addr[2:0];
								end

								if (ctrl.is_amo && amo_misaligned(ctrl.funct3, addr)) begin
									fault_detail <= SV39_FAULT_NONE;
									fault_cause <= STORE_AMO_ADDRESS_MISALIGNED;
									fault_value <= addr;
									state <= Fault;
								end else if (!need_translate && access_misaligned(ctrl.funct3, addr) && !is_normal_memory(addr)) begin
									fault_detail <= SV39_FAULT_NONE;
									fault_cause <= ctrl.is_load ? LOAD_ADDRESS_MISALIGNED : STORE_AMO_ADDRESS_MISALIGNED;
									fault_value <= addr;
									state <= Fault;
								end else if (need_translate) begin
									// Misaligned RAM/ROM accesses within one page are supported.
									// Cross-page accesses trap to avoid a second translation and
									// partial-store side effects.
									if (({1'b0, addr[11:0]} + {9'b0, access_size_bytes(ctrl.funct3[1:0])}) > 13'd4096) begin
										fault_detail <= SV39_FAULT_NONE;
										fault_cause <= ctrl.is_load ? LOAD_ADDRESS_MISALIGNED : STORE_AMO_ADDRESS_MISALIGNED;
										fault_value <= addr;
										state <= Fault;
								end else begin
									state <= TranslateWait;
								end
							end else begin
								state <= AccessWaitReady;
							end
						end
					end

					TranslateWait: begin
						if (translation_rsp_valid) begin
							if (translation_fault) begin
								fault_detail <= translation_fault_detail;
									fault_cause <= translation_fault_cause;
									fault_value <= translation_fault_value;
									state <= Fault;
								end else if (access_misaligned(req_funct3, req_vaddr) && !is_normal_memory(translation_pa)) begin
									fault_detail <= SV39_FAULT_NONE;
									fault_cause <= req_wen ? STORE_AMO_ADDRESS_MISALIGNED : LOAD_ADDRESS_MISALIGNED;
									fault_value <= req_vaddr;
									state <= Fault;
								end else begin
									req_paddr <= translation_pa;
									state <= AccessWaitReady;
							end
						end
					end

					AccessWaitReady: begin
						if (membus.ready) begin
							if (req_wen && !req_is_amo) begin
								state <= req_crosses_word ? SplitAccessWaitReady : Init;
							end else begin
								state <= AccessWaitValid;
							end
						end
					end

					AccessWaitValid: begin
						if (data_mem_rvalid) begin
							if (req_crosses_word) begin
								req_first_rdata <= membus.rdata;
								if ($test$plusargs("TRACE_MEMUNIT")) begin
									$display("[MEMU] split first addr=%h data=%h offset=%0d size=%0d",
										req_paddr, membus.rdata, req_offset, req_size);
								end
								state <= SplitAccessWaitReady;
							end else begin
								state <= Init;
							end
						end
					end

					SplitAccessWaitReady: begin
						if (membus.ready) begin
							state <= req_wen ? Init : SplitAccessWaitValid;
						end
					end

					SplitAccessWaitValid: begin
						if (data_mem_rvalid) begin
							load_result <= extract_load_data({membus.rdata, req_first_rdata}, req_offset, req_funct3);
							if ($test$plusargs("TRACE_MEMUNIT")) begin
								$display("[MEMU] split second addr=%h data=%h result=%h funct3=%b",
									({req_paddr[XLEN-1:3], 3'b000} + Addr'(8)),
									membus.rdata,
									extract_load_data({membus.rdata, req_first_rdata}, req_offset, req_funct3),
									req_funct3);
							end
							state <= Init;
						end
					end

					DiscardWaitValid: begin
						if (membus.rvalid || mem_owner == MemOwnerNone) begin
							state <= Init;
						end
					end

					Fault: begin
						state <= Init;
					end

					default: state <= Init;
				endcase
			end
		end
	end
endmodule : memunit
