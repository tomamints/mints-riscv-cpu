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
		Fault
	} State;

	State state;

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

	CsrCause ptw_fault_cause;

	localparam int W = XLEN;
	logic [MEMBUS_DATA_WIDTH-1:0] D;
	logic sext;
	logic satp_sv39;
	logic need_translate;
	logic ptw_start;
	logic ptw_ready;
	logic ptw_done;
	logic ptw_fault;
	Sv39Fault ptw_fault_detail;
	Addr ptw_pa;
	Addr ptw_fault_value;
	logic ptw_mem_valid;
	Addr ptw_mem_addr;
	PmpAccessType ptw_access_type;
	logic ptw_leaf_valid;
	UIntX ptw_leaf_pte;
	logic [1:0] ptw_leaf_level;

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
	assign ptw_start = state == TranslateWait && ptw_ready;
	assign ptw_access_type = (req_wen || req_is_amo) ? PMP_ACCESS_WRITE : PMP_ACCESS_READ;

	sv39_ptw ptw (
		.clk(clk),
		.rst(rst),
		.flush(1'b0),
		.start(ptw_start),
		.ready(ptw_ready),
		.va(req_vaddr),
		.access_type(ptw_access_type),
		.priv_mode(priv_mode),
		.satp(satp),
		.sum(sstatus_sum),
		.mxr(sstatus_mxr),
		.done(ptw_done),
		.fault(ptw_fault),
		.fault_detail(ptw_fault_detail),
		.pa(ptw_pa),
		.fault_cause(ptw_fault_cause),
		.fault_value(ptw_fault_value),
		.leaf_valid(ptw_leaf_valid),
		.leaf_pte(ptw_leaf_pte),
		.leaf_level(ptw_leaf_level),
		.mem_valid(ptw_mem_valid),
		.mem_addr(ptw_mem_addr),
		.mem_ready(membus.ready),
		.mem_rvalid(membus.rvalid),
		.mem_error(1'b0),
		.mem_rdata(membus.rdata)
	);

	always_comb begin
		D = membus.rdata;
		sext = (ctrl.funct3[2] == 1'b0);

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

		if (ptw_mem_valid) begin
			membus.valid = 1'b1;
			membus.addr = ptw_mem_addr;
		end else if (state == AccessWaitReady) begin
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
		end else if (state == SplitAccessWaitReady) begin
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

		if (req_crosses_word && state == SplitAccessWaitValid && membus.rvalid) begin
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
			AccessWaitValid: stall = valid & (~membus.rvalid || req_crosses_word);
			SplitAccessWaitReady: stall = valid;
			SplitAccessWaitValid: stall = valid & ~membus.rvalid;
			Fault:           stall = 1'b0;
			default:         stall = 1'b0;
		endcase
	end

	always_comb begin
		expt = '0;
		if (state == Fault) begin
			expt.valid = 1'b1;
			expt.cause = ptw_fault_cause;
			expt.value = ptw_fault_value;
			if ($test$plusargs("TRACE_SV39")) begin
				$display("[SV39] FAULT cause=%0d detail=%0d value=%h",
					ptw_fault_cause, ptw_fault_detail, ptw_fault_value);
			end
		end
	end

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state <= Init;
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
		end else begin
			if (!valid) begin
				state <= Init;
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
							req_crosses_word <= ({1'b0, addr[2:0]} + access_size_bytes(ctrl.funct3[1:0])) > 4'd8;

							if (({1'b0, addr[2:0]} + access_size_bytes(ctrl.funct3[1:0])) > 4'd8) begin
								req_wmask <= byte_mask(4'd8 - {1'b0, addr[2:0]}) << addr[2:0];
							end else begin
								req_wmask <= byte_mask(access_size_bytes(ctrl.funct3[1:0])) << addr[2:0];
							end

							if (need_translate) begin
								state <= TranslateWait;
							end else begin
								state <= AccessWaitReady;
							end
						end
					end

					TranslateWait: begin
						if (ptw_done) begin
							if (ptw_fault) begin
								state <= Fault;
							end else begin
								req_paddr <= ptw_pa;
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
						if (membus.rvalid) begin
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
						if (membus.rvalid) begin
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

					Fault: begin
						state <= Init;
					end

					default: state <= Init;
				endcase
			end
		end
	end
endmodule : memunit
