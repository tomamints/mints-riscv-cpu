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
		Fault
	} State;

	State state;

	logic req_wen;
	Addr req_vaddr;
	Addr req_paddr;
	logic [MEMBUS_DATA_WIDTH-1:0] req_wdata;
	logic [(MEMBUS_DATA_WIDTH/8)-1:0] req_wmask;
	logic req_is_amo;
	AMOOp req_amoop;
	logic req_aq;
	logic req_rl;
	logic [2:0] req_funct3;

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

	assign satp_sv39 = satp[63:60] == 4'd8;
	assign need_translate = satp_sv39 && (priv_mode != M);
	assign ptw_start = state == TranslateWait && ptw_ready;
	assign ptw_access_type = (req_wen || req_is_amo) ? PMP_ACCESS_WRITE : PMP_ACCESS_READ;

	sv39_ptw ptw (
		.clk(clk),
		.rst(rst),
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
		end

		case (ctrl.funct3[1:0])
			2'b00: begin
				case(addr[2:0])
					3'd0: rdata = {{(W-8){sext & D[7]}}, D[7:0]};
					3'd1: rdata = {{(W-8){sext & D[15]}}, D[15:8]};
					3'd2: rdata = {{(W-8){sext & D[23]}}, D[23:16]};
					3'd3: rdata = {{(W-8){sext & D[31]}}, D[31:24]};
					3'd4: rdata = {{(W-8){sext & D[39]}}, D[39:32]};
					3'd5: rdata = {{(W-8){sext & D[47]}}, D[47:40]};
					3'd6: rdata = {{(W-8){sext & D[55]}}, D[55:48]};
					3'd7: rdata = {{(W-8){sext & D[63]}}, D[63:56]};
					default: rdata = 'x;
				endcase
			end
			2'b01: begin
				case(addr[2:0])
					3'd0: rdata = {{(W-16){sext & D[15]}}, D[15:0]};
					3'd2: rdata = {{(W-16){sext & D[31]}}, D[31:16]};
					3'd4: rdata = {{(W-16){sext & D[47]}}, D[47:32]};
					3'd6: rdata = {{(W-16){sext & D[63]}}, D[63:48]};
					default: rdata = 'x;
				endcase
			end
			2'b10: begin
				case(addr[2:0])
					3'd0: rdata = {{(W-32){sext & D[31]}}, D[31:0]};
					3'd4: rdata = {{(W-32){sext & D[63]}}, D[63:32]};
					default: rdata = 'x;
				endcase
			end
			2'b11: rdata = D;
			default: rdata = 'x;
		endcase

		case (state)
			Init:            stall = valid & (is_new && inst_is_memop(ctrl));
			TranslateWait:   stall = valid;
			AccessWaitReady: stall = valid;
			AccessWaitValid: stall = valid & ~membus.rvalid;
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
			req_wdata <= '0;
			req_wmask <= '0;
			req_is_amo <= 1'b0;
			req_amoop <= AMOOp'(0);
			req_aq <= 1'b0;
			req_rl <= 1'b0;
			req_funct3 <= '0;
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
							req_wdata <= rs2 << {addr[2:0], 3'b0};
							req_is_amo <= ctrl.is_amo;
							req_amoop <= AMOOp'(ctrl.funct7[6:2]);
							req_aq <= ctrl.funct7[1];
							req_rl <= ctrl.funct7[0];
							req_funct3 <= ctrl.funct3;

							case(ctrl.funct3[1:0])
								2'b00: req_wmask <= 8'b00000001 << addr[2:0];
								2'b01: begin
									case (addr[2:0])
										3'd6: req_wmask <= 8'b11000000;
										3'd4: req_wmask <= 8'b00110000;
										3'd2: req_wmask <= 8'b00001100;
										3'd0: req_wmask <= 8'b00000011;
										default: req_wmask <= 'x;
									endcase
								end
								2'b10: begin
									case (addr[2:0])
										3'd0: req_wmask <= 8'b00001111;
										3'd4: req_wmask <= 8'b11110000;
										default: req_wmask <= 'x;
									endcase
								end
								2'b11: req_wmask <= 8'b11111111;
								default: req_wmask <= 'x;
							endcase

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
							state <= AccessWaitValid;
						end
					end

					AccessWaitValid: begin
						if (membus.rvalid) begin
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
