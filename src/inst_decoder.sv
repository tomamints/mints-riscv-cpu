import eei::*;
import corectrl::*;

module inst_decoder(
	input  Inst     bits,
	input  logic    is_rvc,
	output logic    valid,
	output InstCtrl ctrl,
	output UIntX    imm
	);
	logic [11:0] imm_i_g = bits[31:20];
	logic [11:0] imm_s_g = {bits[31:25],bits[11:7]};
	logic [11:0] imm_b_g = {bits[31],bits[7],bits[30:25],bits[11:8]};
	logic [19:0] imm_u_g = bits[31:12];
	logic [19:0] imm_j_g = {bits[31],bits[19:12],bits[20],bits[30:21]};

	UIntX imm_i = {{(XLEN - $bits(imm_i_g)){bits[31]}}, imm_i_g};
	UIntX imm_s = {{(XLEN - $bits(imm_s_g)){bits[31]}}, imm_s_g};
	UIntX imm_b = {{(XLEN - $bits(imm_b_g) - 1){bits[31]}},  imm_b_g,1'b0};
	UIntX imm_u = {{(XLEN - $bits(imm_u_g) - 12){bits[31]}} , imm_u_g, 12'b0};
	UIntX imm_j = {{(XLEN - $bits(imm_j_g) - 1){bits[31]}} , imm_j_g, 1'b0};

	logic[6:0] op = bits[6:0]; // assign op = bits[6:0]と同じ理解
	logic[6:0] f7 = bits[31:25];
	logic[2:0] f3 = bits[14:12];
	//bitsで送られてきた内容をそれぞれ判定用の変数に割り当てる

	localparam T = 1'b1;
	localparam F = 1'b0;

    logic valid_pre;

	always_comb begin
		unique case (op)
			OP_LUI,
			OP_AUIPC,
			OP_JAL,
			OP_JALR: begin
				valid_pre = T;
			end

			OP_BRANCH: begin
				valid_pre = (f3 != 3'b010) && (f3 != 3'b011);
			end

			OP_LOAD: begin
				valid_pre = (f3 != 3'b111);
			end

			OP_STORE: begin
				valid_pre = (f3[2] == 1'b0);
			end

			OP_OP: begin
				unique case (f7)
					7'b0000000: valid_pre = T; // RV64I
					7'b0100000: valid_pre = (f3 == 3'b000) || (f3 == 3'b101); // SUB, SRA
					7'b0000001: valid_pre = T; // RV64M (MUL/DIV/REM)
					default   : valid_pre = F;
				endcase
			end

			OP_OP_IMM: begin
				unique case (f3)
					3'b001: valid_pre = (f7[6:1] == 6'b000000); // SLLI
					3'b101: valid_pre = (f7[6:1] == 6'b000000) || (f7[6:1] == 6'b010000); // SRLI,SRAI
					default: valid_pre = T;
				endcase
			end

			OP_OP_32: begin
				unique case (f7)
					7'b0000001: valid_pre = (f3 == 3'b000) || (f3[2] == 1'b1); // MULW,DIVW,REMW
					7'b0000000: valid_pre = (f3 == 3'b000) || (f3 == 3'b001) || (f3 == 3'b101); // ADDW,SLLW,SRLW
					7'b0100000: valid_pre = (f3 == 3'b000) || (f3 == 3'b101); // SUBW,SRAW
					default   : valid_pre = F;
				endcase
			end

			OP_OP_IMM_32: begin
				unique case (f3)
					3'b000: valid_pre = T; // ADDIW
					3'b001: valid_pre = (f7 == 7'b0000000); // SLLIW
					3'b101: valid_pre = (f7 == 7'b0000000) || (f7 == 7'b0100000); // SRLIW,SRAIW
					default: valid_pre = F;
				endcase
			end

			OP_SYSTEM: begin
				valid_pre =  (f3 != 3'b000 && f3 != 3'b100) || // CSR系
						(bits == 32'h00000073)        || // ECALL
						(bits == 32'h00100073)        || // EBREAK
						(bits == 32'h30200073)        || // MRET
						(bits == 32'h10200073)        || // SRET
						(bits == 32'h10500073)        || //WFI
						(f3 == 3'b000 && f7 == 7'b0001001); // SFENCE.VMA
			end

			OP_MISC_MEM: begin
				valid_pre = T; // FENCE
			end

			OP_AMO: begin
				valid_pre = (f3 == 3'b010) || (f3 == 3'b011); //AMO
			end

			default: begin
				valid_pre = F;
			end
		endcase

		valid = valid_pre && ((IALIGN == 16) || (!is_rvc));

		case (op)
			OP_LUI,OP_AUIPC        : imm = imm_u;
			OP_JAL                 : imm = imm_j;
			OP_JALR, OP_LOAD       : imm = imm_i;
			OP_OP_IMM,OP_OP_IMM_32 : imm = imm_i;
			OP_BRANCH              : imm = imm_b;
			OP_STORE               : imm = imm_s;
			default                : imm = 'x;
		endcase
		ctrl.itype    = INST_X;
		ctrl.rwb_en   = F;
		ctrl.is_lui   = F;
		ctrl.is_aluop = F;
		ctrl.is_muldiv = F;
		ctrl.is_op32  = F;
		ctrl.is_jump  = F;
		ctrl.is_load  = F;

		ctrl.funct3 = f3;
		ctrl.funct7 = f7;
		ctrl.is_rvc = is_rvc;

		ctrl.is_csr = F;

		ctrl.is_amo = F;

		unique case (op)
		OP_LUI: begin
			ctrl.itype = INST_U;
			ctrl.rwb_en = T;
			ctrl.is_lui = T;
		end
		OP_AUIPC: begin
			ctrl.itype = INST_U;
			ctrl.rwb_en = T;
		end
		OP_JAL:begin
			ctrl.itype = INST_J;
			ctrl.rwb_en = T;
			ctrl.is_jump = T;
		end
		OP_JALR:begin
			ctrl.itype = INST_I;
			ctrl.rwb_en = T;
			ctrl.is_jump = T;
		end
		OP_BRANCH:begin
			ctrl.itype = INST_B;
		end
		OP_LOAD:begin
			ctrl.itype = INST_I;
			ctrl.rwb_en = T;
			ctrl.is_load = T;
		end
		OP_STORE:begin
			ctrl.itype = INST_S;
		end
		OP_OP:begin
			ctrl.itype = INST_R;
			ctrl.rwb_en = T;
			ctrl.is_aluop = T;
		    ctrl.is_muldiv = f7 == 7'b0000001;
		end
		OP_OP_IMM:begin
			ctrl.itype = INST_I;
			ctrl.rwb_en = T;
			ctrl.is_aluop = T;
		end
		OP_OP_32:begin
			ctrl.itype    = INST_R;
			ctrl.rwb_en   = T;
			ctrl.is_aluop = T;
		    ctrl.is_muldiv = f7 == 7'b0000001;
			ctrl.is_op32  = T;
		end
		OP_OP_IMM_32:begin
			ctrl.itype    = INST_I;
			ctrl.rwb_en   = T;
			ctrl.is_aluop = T;
			ctrl.is_op32  = T;
		end
		OP_SYSTEM:begin
			ctrl.itype = INST_I;
			ctrl.rwb_en = (f3 != 3'b000);
			ctrl.is_csr = (f3 != 3'b000);
		end
		OP_AMO:begin
			ctrl.itype = INST_R;
			ctrl.rwb_en = T;
			ctrl.is_amo = T;
		end
		default: begin
			ctrl.itype = INST_X;
		end
	endcase
end
endmodule :inst_decoder
