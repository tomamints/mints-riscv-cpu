import eei::*;
import corectrl::*;

module core (
	input logic clk,
	input logic rst,
	core_inst_if.master i_membus,
	core_data_if.master d_membus,
	output UIntX led,
	output PrivMode pmp_priv_mode,
	output UIntX pmpcfg0_fetch_value,
	output UIntX pmpaddr0_fetch_value,
	output UIntX pmpaddr1_fetch_value,
	output UIntX pmpaddr2_fetch_value,
	output UIntX pmpaddr3_fetch_value,
	output UIntX pmpaddr4_fetch_value,
	output UIntX pmpaddr5_fetch_value,
	output UIntX pmpaddr6_fetch_value,
	output UIntX pmpaddr7_fetch_value,
	output UIntX satp_fetch_value,
	output logic translation_flush_fetch_value,
	output logic sstatus_sum_fetch_value,
	output logic sstatus_mxr_fetch_value,
	input  logic external_meip,
	input  logic external_seip,
	aclint_if.slave aclint
);


	typedef struct packed {
		Addr addr;
		Inst bits;
		InstCtrl ctrl;
		UIntX imm;
		ExceptionInfo expt;
	}exq_type;


	typedef struct packed {
		Addr addr;
		Inst bits;
		InstCtrl ctrl;
		UIntX imm;
		ExceptionInfo expt;
		UIntX alu_result;
		logic[4:0] rs1_addr;
		UIntX rs1_data;
		UIntX rs2_data;
		logic br_taken;
		Addr jump_addr;
	}memq_type;

	typedef struct packed {
		Addr addr;
		Inst bits;
		InstCtrl ctrl;
		UIntX imm;
		UIntX alu_result;
		UIntX mem_rdata;
		UIntX csr_rdata;
		logic raise_trap;
	}wbq_type;



	//ID -> EX FIFO
	logic exq_wready;
	logic exq_wvalid;
	exq_type exq_wdata;
	logic exq_rready;
	logic exq_rvalid;
	exq_type exq_rdata;

	//EX -> MEM FIFO
	logic memq_wready;
	logic memq_wvalid;
	memq_type memq_wdata;
	logic memq_rready;
	logic memq_rvalid;
	memq_type memq_rdata;

	//MEM -> WB FIFO
	logic wbq_wready;
	logic wbq_wvalid;
	wbq_type wbq_wdata;
	logic wbq_rready;
	logic wbq_rvalid;
	wbq_type wbq_rdata;


//////////////////////// IF Stage /////////////////////

	logic control_hazard;
	Addr control_hazard_pc_next;


	always_comb begin
		i_membus.is_hazard = control_hazard;
		i_membus.next_pc   = control_hazard_pc_next;
	end

/*
	always_ff @(posedge clk) begin
		if (if_fifo_rvalid) begin
			$display("[ID] RECEIVED inst(bits)=%h pc=%h",
				if_fifo_rdata.bits,
				if_fifo_rdata.addr
			);
		end
	end
*/


////////////////// ID Stage /////////////////////
	logic ids_valid = i_membus.rvalid;
	Addr ids_pc = i_membus.raddr;
	Inst ids_inst_bits = i_membus.rdata;
	logic ids_inst_valid;
	InstCtrl ids_ctrl;
	UIntX ids_imm;

	inst_decoder decoder (
		.bits (ids_inst_bits),
		.is_rvc (i_membus.is_rvc),
		.valid (ids_inst_valid),
		.ctrl (ids_ctrl),
		.imm  (ids_imm)
	);

	always_comb begin
		//ID -> EX
		i_membus.rready = exq_wready;
		exq_wvalid     = i_membus.rvalid;
		exq_wdata.addr = i_membus.raddr;
		exq_wdata.bits = i_membus.rdata;
		exq_wdata.ctrl = ids_ctrl;
		exq_wdata.imm  = ids_imm;
		// exception
		exq_wdata.expt = i_membus.expt;
		if (!exq_wdata.expt.valid && !ids_inst_valid) begin
			//illegal instruction
			exq_wdata.expt.valid = 1;
			exq_wdata.expt.cause = ILLEGAL_INSTRUCTION;
			exq_wdata.expt.value = {{(XLEN-ILEN){1'b0}},ids_inst_bits};
		end else if (!exq_wdata.expt.valid && ids_inst_bits == 32'h00000073) begin
			//ECALL
			exq_wdata.expt.valid = 1;
			exq_wdata.expt.cause = ENVIRONMENT_CALL_FROM_U_MODE;
			exq_wdata.expt.cause[1:0] = csru_priv_mode; //adjust mode
			exq_wdata.expt.value = 0;
		end else if (!exq_wdata.expt.valid && ids_inst_bits == 32'h00100073) begin
			//EBREAK
			exq_wdata.expt.valid = 1;
			exq_wdata.expt.cause = BREAKPOINT;
			exq_wdata.expt.value = ids_pc;
		end
	end

	////////////////EX Stage /////////////////

	logic exs_valid      = exq_rvalid;
	Addr  exs_pc         = exq_rdata.addr;
	Inst  exs_inst_bits  = exq_rdata.bits;
	InstCtrl  exs_ctrl   = exq_rdata.ctrl;
	UIntX  exs_imm       = exq_rdata.imm;


	//レジスタ
	UIntX regfile [31:0]; //regfileを32個作った

	//レジスタ番号
	logic [4:0] exs_rs1_addr = exs_inst_bits[19:15];
	logic [4:0] exs_rs2_addr = exs_inst_bits[24:20];

	UIntX exs_rs1_data,exs_rs2_data;

	//ソースレジスタのデータ
	always_comb begin
		exs_rs1_data = (exs_rs1_addr == 0) ? '0 : regfile[exs_rs1_addr];
		exs_rs2_data = (exs_rs2_addr == 0) ? '0 : regfile[exs_rs2_addr];
	end

	// Data Hazard

	logic exs_mem_data_hazard, exs_wb_data_hazard, exs_data_hazard;


	assign exs_mem_data_hazard = mems_valid && mems_ctrl.rwb_en && (mems_rd_addr != 5'd0) && ((mems_rd_addr == exs_rs1_addr) || (mems_rd_addr == exs_rs2_addr));
	assign exs_wb_data_hazard = wbs_valid && wbs_ctrl.rwb_en && (wbs_rd_addr != 5'd0) && (wbs_rd_addr == exs_rs1_addr || wbs_rd_addr == exs_rs2_addr);
	assign exs_data_hazard = exs_mem_data_hazard || exs_wb_data_hazard;
/*
	always_ff @(posedge clk)begin
		$display("DECODE: inst=%h itype=%0d is_muldiv=%b funct7=%0d imm=%h",
         ids_inst_bits,
         ids_ctrl.itype,
         ids_ctrl.is_muldiv,
         ids_ctrl.funct7,
         ids_imm);
		$display("mem_data_hazard = %d",exs_mem_data_hazard);
		$display("mems_valid = %d",mems_valid);
		$display("mems_ctrl.rwb_en = %d",mems_ctrl.rwb_en);
		$display("mems_rd_addr = %d",mems_rd_addr);
		$display("exs_rs1_addr = %d",exs_rs1_addr);
		$display("compare = %d",mems_rd_addr == exs_rs1_addr);
	end
*/
	//ALU

	UIntX exs_op1,exs_op2,exs_alu_result;

	always_comb begin
		case (exs_ctrl.itype)
			INST_R, INST_B: begin
				exs_op1 = exs_rs1_data;
				exs_op2 = exs_rs2_data;
			end
			INST_I, INST_S: begin
				exs_op1 = exs_rs1_data;
				exs_op2 = exs_imm;
			end
			INST_U, INST_J: begin
				exs_op1 = exs_pc;
				exs_op2 = exs_imm;
			end
			default: begin
				exs_op1 = 'x;
				exs_op2 = 'x;
			end
		endcase
	end

	alu alum (
		.ctrl (exs_ctrl),
		.op1  (exs_op1),
		.op2  (exs_op2),
		.result(exs_alu_result)
	);


	logic exs_muldiv_valid;
	assign exs_muldiv_valid = exs_valid && exs_ctrl.is_muldiv && !exs_data_hazard && !exs_muldiv_is_requested;
	logic exs_muldiv_ready;
	logic exs_muldiv_rvalid;
	UIntX exs_muldiv_result;
	logic exs_muldiv_accept;


	muldivunit mdu (
		.clk    (clk),
		.rst    (rst),
		.valid  (exs_muldiv_valid),
		.ready  (exs_muldiv_ready),
		.funct3 (exs_ctrl.funct3),
		.is_op32(exs_ctrl.is_op32),
		.op1    (exs_op1),
		.op2    (exs_op2),
		.rvalid (exs_muldiv_rvalid),
		.result (exs_muldiv_result)
	);


	logic exs_muldiv_is_requested;
	assign exs_muldiv_accept = exs_muldiv_valid && exs_muldiv_ready;

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			exs_muldiv_is_requested <= 1'b0;
		end else begin
			// 次のステージに遷移
			if (exq_rvalid && exq_rready) begin
				exs_muldiv_is_requested <= 1'b0;
			end else begin
				// muldivunit にリクエストしたか判定
				if (exs_muldiv_accept) begin
					exs_muldiv_is_requested <= 1'b1;
				end
			end
		end
	end

	logic exs_muldiv_rvalided;
	logic exs_muldiv_stall;

	assign exs_muldiv_stall =
		exs_valid &&
		exs_ctrl.is_muldiv &&
		(!exs_muldiv_is_requested || (!exs_muldiv_rvalid && !exs_muldiv_rvalided));

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			exs_muldiv_rvalided <= 1'b0;
		end else begin
			// 次のステージに遷移
			if (exq_rvalid && exq_rready) begin
				exs_muldiv_rvalided <= 1'b0;
			end else if (exs_muldiv_is_requested) begin
				// muldivunitの処理が完了していたら1にする
				exs_muldiv_rvalided <= exs_muldiv_rvalided | exs_muldiv_rvalid;
			end
		end
	end


	logic exs_brunit_take;
	brunit bru(
		.funct3(exs_ctrl.funct3),
		.op1(exs_op1),
		.op2(exs_op2),
		.take(exs_brunit_take)
	);

	logic exs_stall;
	assign exs_stall = exs_data_hazard || exs_muldiv_stall;

		logic instruction_address_misaligned;
		Addr memaddr;
		logic loadstore_address_misaligned;
		logic loadstore_pmp_fault;
		UIntX loadstore_access_size;

		UIntX pmpcfg0_value;
		UIntX pmpaddr0_value;
		UIntX pmpaddr1_value;
		UIntX pmpaddr2_value;
		UIntX pmpaddr3_value;
		UIntX pmpaddr4_value;
		UIntX pmpaddr5_value;
		UIntX pmpaddr6_value;
		UIntX pmpaddr7_value;
		UIntX satp_value;
		logic sstatus_sum;
		logic sstatus_mxr;
			logic pmp_data_allow;
			PrivMode csru_priv_mode;
			PrivMode csru_mem_priv_mode;
			UIntX csru_rdata;
			logic csru_raise_trap;
			Addr csru_trap_vector;
			logic csru_trap_return;
			UInt64 minstret;
			logic minstret_wen;
			UInt64 minstret_wdata;
			UInt64 debug_cycle;
			UInt64 strsize_trace_count;
			UInt64 strsize_muldiv_trace_count;
			UInt64 perf_retired;
			UInt64 perf_commit_cycle;
			UInt64 perf_no_commit_cycle;
			UInt64 perf_ifetch_stall_cycle;
			UInt64 perf_data_hazard_cycle;
			UInt64 perf_muldiv_stall_cycle;
			UInt64 perf_mem_stall_cycle;
			UInt64 perf_other_stall_cycle;
			UInt64 perf_ifetch_active_cycle;
			UInt64 perf_data_hazard_active_cycle;
			UInt64 perf_muldiv_active_cycle;
			UInt64 perf_mem_active_cycle;
			UInt64 perf_branch_count;
			UInt64 perf_branch_taken_count;
			UInt64 perf_control_flush_count;
			UInt64 perf_trap_flush_count;
			UInt64 perf_load_count;
			UInt64 perf_store_count;
			UInt64 perf_ibus_req_count;
			UInt64 perf_dbus_req_count;

		function automatic UIntX mem_access_size(input logic [2:0] funct3);
			unique case (funct3[1:0])
				2'b00 : return UIntX'(1);
				2'b01 : return UIntX'(2);
				2'b10 : return UIntX'(4);
				2'b11 : return UIntX'(8);
				default : return UIntX'(1);
			endcase
		endfunction

		assign memaddr = exs_ctrl.is_amo ? exs_rs1_data : exs_alu_result;
		assign loadstore_access_size = mem_access_size(exs_ctrl.funct3);
		assign pmp_priv_mode = csru_priv_mode;
		assign pmpcfg0_fetch_value = pmpcfg0_value;
		assign pmpaddr0_fetch_value = pmpaddr0_value;
		assign pmpaddr1_fetch_value = pmpaddr1_value;
		assign pmpaddr2_fetch_value = pmpaddr2_value;
		assign pmpaddr3_fetch_value = pmpaddr3_value;
		assign pmpaddr4_fetch_value = pmpaddr4_value;
		assign pmpaddr5_fetch_value = pmpaddr5_value;
		assign pmpaddr6_fetch_value = pmpaddr6_value;
		assign pmpaddr7_fetch_value = pmpaddr7_value;
		assign satp_fetch_value = satp_value;
		assign sstatus_sum_fetch_value = sstatus_sum;
		assign sstatus_mxr_fetch_value = sstatus_mxr;

			pmp_checker pmp_data_checker (
				.priv_mode(csru_mem_priv_mode),
			.access_start(memaddr),
			.access_size(loadstore_access_size),
			.access_type((inst_is_store(exs_ctrl) || exs_ctrl.is_amo) ? PMP_ACCESS_WRITE : PMP_ACCESS_READ),
			.pmpcfg0(pmpcfg0_value),
			.pmpaddr0(pmpaddr0_value),
			.pmpaddr1(pmpaddr1_value),
			.pmpaddr2(pmpaddr2_value),
			.pmpaddr3(pmpaddr3_value),
			.pmpaddr4(pmpaddr4_value),
			.pmpaddr5(pmpaddr5_value),
			.pmpaddr6(pmpaddr6_value),
			.pmpaddr7(pmpaddr7_value),
			.allow(pmp_data_allow)
		);

		always_comb begin
		//EX-> MEM
		exq_rready  = memq_wready && !exs_stall;
		memq_wvalid = exq_rvalid && !exs_stall;
		memq_wdata.addr = exq_rdata.addr;
		memq_wdata.bits = exq_rdata.bits;
		memq_wdata.ctrl = exq_rdata.ctrl;
		memq_wdata.imm = exq_rdata.imm;
		memq_wdata.rs1_addr = exs_rs1_addr;
		memq_wdata.rs1_data = exs_rs1_data;
		memq_wdata.rs2_data = exs_rs2_data;
		memq_wdata.alu_result = (exs_ctrl.is_muldiv) ? exs_muldiv_result : exs_alu_result;
		memq_wdata.br_taken = exs_ctrl.is_jump || inst_is_br(exs_ctrl) && exs_brunit_take;
		memq_wdata.jump_addr = (inst_is_br(exs_ctrl)) ? exs_pc + exs_imm : exs_alu_result & ~1;
			// exception
			instruction_address_misaligned = (IALIGN == 32 && memq_wdata.br_taken && memq_wdata.jump_addr[1:0] != 2'b00);
			if (inst_is_memop(exs_ctrl) && exs_ctrl.is_amo) begin
				unique case (exs_ctrl.funct3[1:0])
					2'b00 : loadstore_address_misaligned = 1'b0;
				2'b01 : loadstore_address_misaligned = (memaddr[0]   != 1'b0); //H
				2'b10 : loadstore_address_misaligned = (memaddr[1:0] != 2'b00); //W
				2'b11 : loadstore_address_misaligned = (memaddr[2:0] != 3'b000); //D
				default : loadstore_address_misaligned = 1'b0;
			endcase
			end else begin
				loadstore_address_misaligned = 1'b0;
			end
			loadstore_pmp_fault =
				inst_is_memop(exs_ctrl) &&
				!loadstore_address_misaligned &&
				!pmp_data_allow;
			memq_wdata.expt = exq_rdata.expt;
			if (!memq_wdata.expt.valid)begin
				if ( instruction_address_misaligned)begin
					memq_wdata.expt.valid = 1;
					memq_wdata.expt.cause = INSTRUCTION_ADDRESS_MISALIGNED;
					memq_wdata.expt.value = memq_wdata.jump_addr;
				end else if (loadstore_address_misaligned) begin
					memq_wdata.expt.valid = 1;
					memq_wdata.expt.cause = (exs_ctrl.is_load) ? LOAD_ADDRESS_MISALIGNED : STORE_AMO_ADDRESS_MISALIGNED;
					memq_wdata.expt.value = memaddr;
				end else if (loadstore_pmp_fault) begin
					memq_wdata.expt.valid = 1;
					memq_wdata.expt.cause = (exs_ctrl.is_load) ? LOAD_ACCESS_FAULT : STORE_AMO_ACCESS_FAULT;
					memq_wdata.expt.value = memaddr;
				end
			end
		end

	////////////MEM Stage ////////////////

	logic mems_is_new;
	logic mems_valid      = memq_rvalid;
	Addr  mems_pc         = memq_rdata.addr;
	Inst  mems_inst_bits  = memq_rdata.bits;
	InstCtrl  mems_ctrl   = memq_rdata.ctrl;
	ExceptionInfo  mems_expt   = memq_rdata.expt;
	logic[4:0]  mems_rd_addr       = mems_inst_bits[11:7];

	logic mems_satp_access;
	logic mems_sfence_vma;
	logic mems_translation_hazard;
	assign mems_satp_access =
		mems_ctrl.is_csr &&
		(mems_inst_bits[31:20] == SATP);
	assign mems_sfence_vma =
		(mems_inst_bits[6:0] == OP_SYSTEM) &&
		(mems_inst_bits[14:12] == 3'b000) &&
		(mems_inst_bits[31:25] == 7'b0001001);
	assign mems_translation_hazard = mems_satp_access || mems_sfence_vma;

	assign control_hazard = mems_valid && (csru_raise_trap || mems_ctrl.is_jump || memq_rdata.br_taken || mems_translation_hazard);
	assign translation_flush_fetch_value =
		mems_valid &&
		mems_is_new &&
		mems_translation_hazard &&
		!csru_raise_trap &&
		!mems_expt.valid;
	assign control_hazard_pc_next =
		(csru_raise_trap) ? csru_trap_vector :
		(mems_translation_hazard) ? mems_pc + Addr'(4) :
		memq_rdata.jump_addr;


	always_ff @(posedge clk or negedge rst) begin
		if(!rst)begin
			mems_is_new <= 1'b0;
		end else begin
			if(memq_rvalid)begin
				mems_is_new <= memq_rready;
			end else begin
				mems_is_new <= 1'b1;
			end
		end
	end

		UIntX memu_rdata;
		logic memu_stall;
		ExceptionInfo memu_expt;
		ExceptionInfo csru_expt_info;
		Addr memu_addr;
		assign memu_addr = mems_ctrl.is_amo ? memq_rdata.rs1_data : memq_rdata.alu_result;
		assign csru_expt_info = mems_expt.valid ? mems_expt : memu_expt;

		memunit memu (
			.clk    (clk),
			.rst    (rst),
			.valid  (mems_valid && !csru_raise_trap && !mems_expt.valid),
			.is_new (mems_is_new),
				.ctrl   (mems_ctrl),
				.priv_mode(csru_mem_priv_mode),
			.satp   (satp_value),
			.sstatus_sum(sstatus_sum),
			.sstatus_mxr(sstatus_mxr),
			.addr   (memu_addr),
			.rs2    (memq_rdata.rs2_data),
			.rdata  (memu_rdata),
			.stall  (memu_stall),
			.expt   (memu_expt),
			.membus (d_membus)
		);

		csrunit csru(
		.clk      (clk),
		.rst      (rst),
		.valid    (mems_valid),
		.pc       (mems_pc),
		.inst_bits(mems_inst_bits),
		.ctrl     (mems_ctrl),
		.expt_info(csru_expt_info),
		.rd_addr  (mems_rd_addr),
		.csr_addr (mems_inst_bits[31:20]),
		.rs1_addr (memq_rdata.rs1_addr),
		.rs1_data (memq_rdata.rs1_data),
			.can_intr (mems_is_new),
			.rdata    (csru_rdata),
				.mode     (csru_priv_mode),
				.raise_trap  (csru_raise_trap),
				.trap_vector (csru_trap_vector),
				.trap_return (csru_trap_return),
				.mem_priv_mode(csru_mem_priv_mode),
				.minstret_wen(minstret_wen),
				.minstret_wdata(minstret_wdata),
				.pmpcfg0_value(pmpcfg0_value),
			.pmpaddr0_value(pmpaddr0_value),
			.pmpaddr1_value(pmpaddr1_value),
			.pmpaddr2_value(pmpaddr2_value),
			.pmpaddr3_value(pmpaddr3_value),
			.pmpaddr4_value(pmpaddr4_value),
			.pmpaddr5_value(pmpaddr5_value),
			.pmpaddr6_value(pmpaddr6_value),
			.pmpaddr7_value(pmpaddr7_value),
			.satp_value(satp_value),
			.sstatus_sum(sstatus_sum),
			.sstatus_mxr(sstatus_mxr),
			.minstret (minstret),
			.external_meip(external_meip),
			.external_seip(external_seip),
			.aclint(aclint)
		);


	always_comb begin
		//MEM -> WB
		memq_rready = wbq_wready && !memu_stall;
		wbq_wvalid = memq_rvalid && !memu_stall;
		wbq_wdata.addr = memq_rdata.addr;
		wbq_wdata.bits = memq_rdata.bits;
		wbq_wdata.ctrl = memq_rdata.ctrl;
		wbq_wdata.imm = memq_rdata.imm;
		wbq_wdata.alu_result = memq_rdata.alu_result;
		wbq_wdata.mem_rdata = memu_rdata;
		wbq_wdata.csr_rdata = csru_rdata;
		wbq_wdata.raise_trap = csru_raise_trap && !csru_trap_return;
	end

	//////////WB Stage //////////

	logic wbs_valid      = wbq_rvalid;
	Addr  wbs_pc         = wbq_rdata.addr;
	Inst  wbs_inst_bits  = wbq_rdata.bits;
	InstCtrl  wbs_ctrl   = wbq_rdata.ctrl;
	UIntX  wbs_imm       = wbq_rdata.imm;

	logic [4:0] wbs_rd_addr = wbs_inst_bits[11:7];
	UIntX wbs_wb_data;
	logic wbs_writes_minstret;
	logic architectural_retire;
	logic minstret_auto_increment;
	logic perf_ifetch_stall;
	logic perf_data_hazard_stall;
	logic perf_muldiv_stall;
	logic perf_mem_stall;
	logic perf_branch_event;
	logic perf_control_flush_event;
	logic perf_trap_flush_event;
	logic perf_load_event;
	logic perf_store_event;
	assign wbs_writes_minstret = wbs_ctrl.is_csr && (wbs_inst_bits[31:20] == MINSTRET) && (wbs_inst_bits[13:12] != 2'b00);
	assign architectural_retire = wbq_rvalid && wbq_rready && !wbq_rdata.raise_trap;
	assign minstret_auto_increment = architectural_retire && !wbs_writes_minstret;
	assign perf_ifetch_stall = !ids_valid && !control_hazard;
	assign perf_data_hazard_stall = exs_valid && exs_data_hazard;
	assign perf_muldiv_stall = exs_muldiv_stall;
	assign perf_mem_stall = memu_stall;
	assign perf_branch_event = mems_valid && mems_is_new && inst_is_br(mems_ctrl);
	assign perf_control_flush_event =
		mems_valid &&
		mems_is_new &&
		(csru_raise_trap || mems_ctrl.is_jump || memq_rdata.br_taken || mems_translation_hazard);
	assign perf_trap_flush_event = mems_valid && mems_is_new && csru_raise_trap && !csru_trap_return;
	assign perf_load_event = architectural_retire && wbs_ctrl.is_load;
	assign perf_store_event = architectural_retire && inst_is_store(wbs_ctrl);

	function automatic string linux_syscall_name(input UIntX nr);
		case (nr)
			UIntX'(17):  return "getcwd";
			UIntX'(29):  return "ioctl";
			UIntX'(40):  return "mount";
			UIntX'(56):  return "openat";
			UIntX'(57):  return "close";
			UIntX'(61):  return "getdents64";
			UIntX'(62):  return "lseek";
			UIntX'(63):  return "read";
			UIntX'(64):  return "write";
			UIntX'(66):  return "writev";
			UIntX'(78):  return "readlinkat";
			UIntX'(79):  return "newfstatat";
			UIntX'(80):  return "fstat";
			UIntX'(93):  return "exit";
			UIntX'(94):  return "exit_group";
			UIntX'(96):  return "set_tid_address";
			UIntX'(98):  return "futex";
			UIntX'(99):  return "set_robust_list";
			UIntX'(101): return "nanosleep";
			UIntX'(113): return "clock_gettime";
			UIntX'(129): return "kill";
			UIntX'(134): return "rt_sigaction";
			UIntX'(135): return "rt_sigprocmask";
			UIntX'(160): return "uname";
			UIntX'(172): return "getpid";
			UIntX'(173): return "getppid";
			UIntX'(174): return "getuid";
			UIntX'(175): return "geteuid";
			UIntX'(176): return "getgid";
			UIntX'(177): return "getegid";
			UIntX'(214): return "brk";
			UIntX'(215): return "munmap";
			UIntX'(221): return "execve";
			UIntX'(222): return "mmap";
			UIntX'(226): return "mprotect";
			UIntX'(260): return "wait4";
			UIntX'(261): return "prlimit64";
			default:     return "unknown";
		endcase
	endfunction

	always_comb begin
		if (wbs_ctrl.is_lui) begin
			wbs_wb_data = wbs_imm;
		end else if (wbs_ctrl.is_jump) begin
			wbs_wb_data = wbs_pc + (wbs_ctrl.is_rvc ? 2 : 4); // XLEN 64 前提
		end else if (wbs_ctrl.is_load || wbs_ctrl.is_amo) begin
			wbs_wb_data = wbq_rdata.mem_rdata;
		end else if (wbs_ctrl.is_csr) begin
			wbs_wb_data = wbq_rdata.csr_rdata;
		end else begin
			wbs_wb_data = wbq_rdata.alu_result;
		end
	end

	always_ff @(posedge clk or negedge rst)begin
		if(!rst)begin
			minstret <= '0;
			debug_cycle <= '0;
			strsize_trace_count <= '0;
			strsize_muldiv_trace_count <= '0;
			perf_retired <= '0;
			perf_commit_cycle <= '0;
			perf_no_commit_cycle <= '0;
			perf_ifetch_stall_cycle <= '0;
			perf_data_hazard_cycle <= '0;
			perf_muldiv_stall_cycle <= '0;
			perf_mem_stall_cycle <= '0;
			perf_other_stall_cycle <= '0;
			perf_ifetch_active_cycle <= '0;
			perf_data_hazard_active_cycle <= '0;
			perf_muldiv_active_cycle <= '0;
			perf_mem_active_cycle <= '0;
			perf_branch_count <= '0;
			perf_branch_taken_count <= '0;
			perf_control_flush_count <= '0;
			perf_trap_flush_count <= '0;
			perf_load_count <= '0;
			perf_store_count <= '0;
			perf_ibus_req_count <= '0;
			perf_dbus_req_count <= '0;
		end else begin
			debug_cycle <= debug_cycle + 1;
			if (architectural_retire) begin
				perf_retired <= perf_retired + 1;
				perf_commit_cycle <= perf_commit_cycle + 1;
			end else begin
				perf_no_commit_cycle <= perf_no_commit_cycle + 1;
				if (perf_mem_stall) begin
					perf_mem_stall_cycle <= perf_mem_stall_cycle + 1;
				end else if (perf_muldiv_stall) begin
					perf_muldiv_stall_cycle <= perf_muldiv_stall_cycle + 1;
				end else if (perf_data_hazard_stall) begin
					perf_data_hazard_cycle <= perf_data_hazard_cycle + 1;
				end else if (perf_ifetch_stall) begin
					perf_ifetch_stall_cycle <= perf_ifetch_stall_cycle + 1;
				end else begin
					perf_other_stall_cycle <= perf_other_stall_cycle + 1;
				end
			end
			if (perf_mem_stall) begin
				perf_mem_active_cycle <= perf_mem_active_cycle + 1;
			end
			if (perf_muldiv_stall) begin
				perf_muldiv_active_cycle <= perf_muldiv_active_cycle + 1;
			end
			if (perf_data_hazard_stall) begin
				perf_data_hazard_active_cycle <= perf_data_hazard_active_cycle + 1;
			end
			if (perf_ifetch_stall) begin
				perf_ifetch_active_cycle <= perf_ifetch_active_cycle + 1;
			end
			if (perf_branch_event) begin
				perf_branch_count <= perf_branch_count + 1;
				if (memq_rdata.br_taken) begin
					perf_branch_taken_count <= perf_branch_taken_count + 1;
				end
			end
			if (perf_control_flush_event) begin
				perf_control_flush_count <= perf_control_flush_count + 1;
			end
			if (perf_trap_flush_event) begin
				perf_trap_flush_count <= perf_trap_flush_count + 1;
			end
			if (perf_load_event) begin
				perf_load_count <= perf_load_count + 1;
			end
			if (perf_store_event) begin
				perf_store_count <= perf_store_count + 1;
			end
			if (i_membus.rvalid && i_membus.rready) begin
				perf_ibus_req_count <= perf_ibus_req_count + 1;
			end
			if (d_membus.valid && d_membus.ready) begin
				perf_dbus_req_count <= perf_dbus_req_count + 1;
			end
			if ($test$plusargs("TRACE_STRSIZE_REDUCE") &&
				wbs_valid &&
				(wbs_pc >= Addr'(64'hffff_ffff_803d_dfee)) &&
				(wbs_pc <= Addr'(64'hffff_ffff_803d_e032)) &&
				(strsize_trace_count < UInt64'(200))) begin
				strsize_trace_count <= strsize_trace_count + 1;
			end
			if ($test$plusargs("TRACE_STRSIZE_MULDIV") &&
				(exs_valid || exs_muldiv_rvalid) &&
				(exs_pc >= Addr'(64'hffff_ffff_803d_dfee)) &&
				(exs_pc <= Addr'(64'hffff_ffff_803d_e002)) &&
				(strsize_muldiv_trace_count < UInt64'(80))) begin
				strsize_muldiv_trace_count <= strsize_muldiv_trace_count + 1;
			end
			if (minstret_wen) begin
				minstret <= minstret_wdata;
			end else if (minstret_auto_increment)begin
				minstret <= minstret + 1;
			end
		end
	end

	final begin
		if ($test$plusargs("PERF_SUMMARY")) begin
			$display("[PERF] cycles=%0d retired=%0d cpi_x1000=%0d ipc_x1000=%0d",
				debug_cycle,
				perf_retired,
				(perf_retired == 0) ? UInt64'(0) : (debug_cycle * UInt64'(1000)) / perf_retired,
				(debug_cycle == 0) ? UInt64'(0) : (perf_retired * UInt64'(1000)) / debug_cycle);
			$display("[PERF] primary commit=%0d no_commit=%0d mem=%0d muldiv=%0d data_hazard=%0d ifetch=%0d other=%0d",
				perf_commit_cycle,
				perf_no_commit_cycle,
				perf_mem_stall_cycle,
				perf_muldiv_stall_cycle,
				perf_data_hazard_cycle,
				perf_ifetch_stall_cycle,
				perf_other_stall_cycle);
			$display("[PERF] active mem=%0d muldiv=%0d data_hazard=%0d ifetch=%0d",
				perf_mem_active_cycle,
				perf_muldiv_active_cycle,
				perf_data_hazard_active_cycle,
				perf_ifetch_active_cycle);
			$display("[PERF] events branch=%0d branch_taken=%0d control_flush=%0d trap_flush=%0d load=%0d store=%0d ibus_req=%0d dbus_req=%0d",
				perf_branch_count,
				perf_branch_taken_count,
				perf_control_flush_count,
				perf_trap_flush_count,
				perf_load_count,
				perf_store_count,
				perf_ibus_req_count,
				perf_dbus_req_count);
		end
	end

	always_ff @(posedge clk)begin
		if(wbs_valid && wbs_ctrl.rwb_en && (wbs_rd_addr != 5'd0) && !wbq_rdata.raise_trap)begin
			regfile[wbs_rd_addr] <= wbs_wb_data;
		end
	end

	always_comb begin
		//WB->END
		wbq_rready = 1;
	end

	always_ff @(posedge clk) begin
		if ($test$plusargs("TRACE_COMMIT") && wbs_valid) begin
			$display("[COMMIT] pc=%h inst=%h trap=%b", wbs_pc, wbs_inst_bits, wbq_rdata.raise_trap);
		end
		if ($test$plusargs("TRACE_HEARTBEAT") && wbs_valid && (minstret[19:0] == 20'h0)) begin
			$display("[HEARTBEAT] minstret=%h pc=%h inst=%h mode=%0d satp=%h trap=%b",
				minstret,
				wbs_pc,
				wbs_inst_bits,
				csru_priv_mode,
				satp_fetch_value,
				wbq_rdata.raise_trap);
		end
		if (($test$plusargs("TRACE_SYSCALL") || $test$plusargs("TRACE_ECALL")) &&
			wbs_valid &&
			wbs_inst_bits == 32'h00000073) begin
			$display("[ECALL] cycle=%h minstret=%h pc=%h mode=%0d trap=%b expt=%b cause=%0d nr=%0d(%s) a0=%h a1=%h a2=%h a3=%h a4=%h a5=%h sp=%h ra=%h satp=%h",
				debug_cycle,
				minstret,
				wbs_pc,
				csru_priv_mode,
				wbq_rdata.raise_trap,
				mems_expt.valid,
				mems_expt.cause,
				regfile[17],
				linux_syscall_name(regfile[17]),
				regfile[10],
				regfile[11],
				regfile[12],
				regfile[13],
				regfile[14],
				regfile[15],
				regfile[2],
				regfile[1],
				satp_fetch_value);
		end
		if ($test$plusargs("TRACE_PIPE") && debug_cycle[19:0] == 20'h0) begin
			$display("[PIPE] cycle=%h minstret=%h mode=%0d satp=%h id_v=%b id_pc=%h ex_v=%b ex_pc=%h ex_stall=%b mem_v=%b mem_pc=%h mem_stall=%b wb_v=%b wb_pc=%h i_rvalid=%b i_rready=%b d_v=%b d_rdy=%b d_rvalid=%b",
				debug_cycle,
				minstret,
				csru_priv_mode,
				satp_fetch_value,
				ids_valid,
				ids_pc,
				exs_valid,
				exs_pc,
				exs_stall,
				mems_valid,
				mems_pc,
				memu_stall,
				wbs_valid,
				wbs_pc,
				i_membus.rvalid,
				i_membus.rready,
				d_membus.valid,
				d_membus.ready,
				d_membus.rvalid);
		end
		if ($test$plusargs("TRACE_STRSIZE_LOOP") &&
			wbs_valid &&
			(wbs_pc >= Addr'(64'hffff_ffff_803d_e024)) &&
			(wbs_pc <= Addr'(64'hffff_ffff_803d_e032))) begin
			$display("[STRSIZE] cycle=%h minstret=%h pc=%h inst=%h rd=%0d wdata=%h a0=%h a1=%h a3=%h a5=%h a6=%h a7=%h s2=%h trap=%b",
				debug_cycle,
				minstret,
				wbs_pc,
				wbs_inst_bits,
				wbs_rd_addr,
				wbs_wb_data,
				regfile[10],
				regfile[11],
				regfile[13],
				regfile[15],
				regfile[16],
				regfile[17],
				regfile[18],
				wbq_rdata.raise_trap);
		end
		if ($test$plusargs("TRACE_STRSIZE_REDUCE") &&
			wbs_valid &&
			(wbs_pc >= Addr'(64'hffff_ffff_803d_dfee)) &&
			(wbs_pc <= Addr'(64'hffff_ffff_803d_e032)) &&
			(strsize_trace_count < UInt64'(200))) begin
			$display("[STRREDUCE] cycle=%h minstret=%h pc=%h inst=%h rd=%0d wdata=%h a0=%h a1=%h a3=%h a4=%h a5=%h a6=%h a7=%h s1=%h s2=%h s7=%h trap=%b",
				debug_cycle,
				minstret,
				wbs_pc,
				wbs_inst_bits,
				wbs_rd_addr,
				wbs_wb_data,
				regfile[10],
				regfile[11],
				regfile[13],
				regfile[14],
				regfile[15],
				regfile[16],
				regfile[17],
				regfile[9],
				regfile[18],
				regfile[23],
				wbq_rdata.raise_trap);
		end
		if ($test$plusargs("TRACE_STRSIZE_MULDIV") &&
			(exs_valid || exs_muldiv_rvalid) &&
			(exs_pc >= Addr'(64'hffff_ffff_803d_dfee)) &&
			(exs_pc <= Addr'(64'hffff_ffff_803d_e002)) &&
			(strsize_muldiv_trace_count < UInt64'(80))) begin
			$display("[STRMULDIV] cycle=%h pc=%h inst=%h valid=%b stall=%b req=%b ready=%b rvalid=%b accept=%b requested=%b rvalided=%b funct3=%b op32=%b rs1=%0d rs1_data=%h rs2=%0d rs2_data=%h op1=%h op2=%h result=%h",
				debug_cycle,
				exs_pc,
				exs_inst_bits,
				exs_valid,
				exs_stall,
				exs_muldiv_valid,
				exs_muldiv_ready,
				exs_muldiv_rvalid,
				exs_muldiv_accept,
				exs_muldiv_is_requested,
				exs_muldiv_rvalided,
				exs_ctrl.funct3,
				exs_ctrl.is_op32,
				exs_rs1_addr,
				exs_rs1_data,
				exs_rs2_addr,
				exs_rs2_data,
				exs_op1,
				exs_op2,
				exs_muldiv_result);
		end
		if ($test$plusargs("TRACE_PAYLOAD") && wbs_valid && wbs_pc >= Addr'('h8020_0000)) begin
			$display("[PAYLOAD] pc=%h inst=%h rd=%0d wdata=%h trap=%b expt=%b cause=%0d value=%h",
				wbs_pc,
				wbs_inst_bits,
				wbs_rd_addr,
				wbs_wb_data,
				wbq_rdata.raise_trap,
				mems_expt.valid,
				mems_expt.cause,
				mems_expt.value);
		end
	end


	assign led = '0;

	/////////////DEBUG ////////////////
///////////////////////////////// DEBUG //////////////////////////////////
`ifdef PRINT_DEBUG

    // ---- ID 管理カウンタ ----
    logic [63:0] gen_inst_id;
    logic [63:0] id_inst_id;
    logic [63:0] ex_inst_id;
    logic [63:0] mem_inst_id;
    logic [63:0] wb_inst_id;

    // --- ID は combinational で gen_inst_id を反映 ---
    always_comb begin
        id_inst_id = gen_inst_id;
    end

    // ---- pipeline inst_id 移動 ----
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            gen_inst_id <= 64'd0;
            ex_inst_id  <= 64'd0;
            mem_inst_id <= 64'd0;
            wb_inst_id  <= 64'd0;
        end else begin
            if (i_membus.rready && i_membus.rvalid) begin
                gen_inst_id <= gen_inst_id + 1;
            end
            if (exq_wready && exq_wvalid) begin
                ex_inst_id <= id_inst_id;
            end
            if (memq_wready && memq_wvalid) begin
                mem_inst_id <= ex_inst_id;
            end
            if (wbq_wready && wbq_wvalid) begin
                wb_inst_id <= mem_inst_id;
            end
        end
    end

    // ---- clock カウンタ ----
    logic [63:0] clock_count;

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            clock_count <= 64'd1;
        end else begin
            clock_count <= clock_count + 1;

            $display("");
            $display("clock,%0d", clock_count);

            // ---------------- ID ----------------
            $display("id.valid,b,%b", ids_valid);
            if (ids_valid) begin
                $display("id.inst_id,d,%0d", id_inst_id);
                $display("id.addr,h,%h", ids_pc);
                $display("id.inst,h,%h", ids_inst_bits);
                $display("id.itype,b,%b", ids_ctrl.itype);
                $display("id.imm,h,%h", ids_imm);
                $display("id.expt.valid,b,%b", exq_wdata.expt.valid);
                if (exq_wdata.expt.valid) begin
                    $display("id.expt.cause,d,%0d", exq_wdata.expt.cause);
                    $display("id.expt.value,d,%0d", exq_wdata.expt.value);
                end
            end

            // ---------------- EX ----------------
            $display("ex.valid,b,%b", exs_valid);
            if (exs_valid) begin
                $display("ex.inst_id,d,%0d", ex_inst_id);
                $display("ex.addr,h,%h", exq_rdata.addr);
                $display("ex.inst,h,%h", exq_rdata.bits);
                $display("ex.expt.valid,b,%b", exq_rdata.expt.valid);
                if (exq_rdata.expt.valid) begin
                    $display("ex.expt.cause,d,%0d", exq_rdata.expt.cause);
                    $display("ex.expt.value,d,%0d", exq_rdata.expt.cause);
                end
                $display("ex.op1,h,%h", exs_op1);
                $display("ex.op2,h,%h", exs_op2);
                $display("ex.alu,h,%h", exs_alu_result);
                $display("ex.dhazard,b,%b", exs_data_hazard);
                $display("ex.muldiv.stall,b,%b", exs_muldiv_stall);

                if (exs_ctrl.is_muldiv && exs_muldiv_rvalid) begin
                    $display("ex.muldiv.result,h,%h", exs_muldiv_result);
                end
                if (inst_is_br(exs_ctrl)) begin
                    $display("ex.br take,b,%b", exs_brunit_take);
                end
            end

            // ---------------- MEM ----------------
            $display("mem.valid,b,%b", mems_valid);
            if (mems_valid) begin
                $display("mem.inst_id,d,%0d", mem_inst_id);
                $display("mem.addr,h,%h", memq_rdata.addr);
                $display("mem.inst,h,%h", memq_rdata.bits);
                $display("mem.stall,b,%b", memu_stall);

                if (inst_is_memop(mems_ctrl)) begin
                    $display("mem.is_load,b,%b", mems_ctrl.is_load);
                    $display("mem.memaddr,h,%h", memu_addr);

                    if (mems_ctrl.is_load) begin
                        if (!memu_stall) begin
                            $display("mem.rdata,h,%h", memu_rdata);
                        end
                    end else begin
                        $display("mem.wdata,h,%h", memq_rdata.rs2_data);
                    end
                end

                if (mems_ctrl.is_csr || csru_raise_trap) begin
                    $display("mem.csr.rdata,h,%h", csru_rdata);
                    $display("mem.csr.trap,b,%b", csru_raise_trap);
                    $display("mem.csr.vec,h,%h", csru_trap_vector);
                end

                if (memq_rdata.br_taken) begin
                    $display("mem.jump.addr,h,%h", memq_rdata.jump_addr);
                end
            end

            // ---------------- WB ----------------
            $display("wb.valid,b,%b", wbs_valid);
            if (wbs_valid) begin
                $display("wb.inst_id,d,%0d", wb_inst_id);
                $display("wb.addr,h,%h", wbq_rdata.addr);
                $display("wb.inst,h,%h", wbq_rdata.bits);
                $display("wb.trap,b,%b", wbq_rdata.raise_trap);

                if (wbs_ctrl.rwb_en && !wbq_rdata.raise_trap) begin
                    $display("wb.rd.wen,b,%b", wbs_ctrl.rwb_en);
                    $display("wb.rd.addr,d,%0d", wbs_rd_addr);
                    $display("wb.rd.data,h,%h", wbs_wb_data);
                end
            end

            // ---------------- flush ----------------
            if (control_hazard) begin
                $display("flush.if,b,1");
                $display("flush.id,b,1");
                $display("flush.ex,b,1");
            end
        end
    end

`endif

	////////////////////////FIFO/////////////////////
	fifo#(
		.DATA_TYPE(exq_type),
		.WIDTH(1)
	)id_ex_fifo(
		.clk (clk),
		.rst (rst),
		.flush(control_hazard),
		.wready_two(),         // ← 追加
		.wready(exq_wready),
		.wvalid(exq_wvalid),
		.wdata(exq_wdata),
		.rready(exq_rready),
		.rvalid(exq_rvalid),
		.rdata(exq_rdata)
	);

	fifo#(
		.DATA_TYPE(memq_type),
		.WIDTH(1)
	)ex_mem_fifo(
		.clk (clk),
		.rst (rst),
		.flush(control_hazard),
		.wready(memq_wready),
		.wready_two(),         // ← 追加
		.wvalid(memq_wvalid),
		.wdata(memq_wdata),
		.rready(memq_rready),
		.rvalid(memq_rvalid),
		.rdata(memq_rdata)
	);


	fifo#(
		.DATA_TYPE(wbq_type),
		.WIDTH(1)
	)mem_wbq_fifo(
		.clk (clk),
		.rst (rst),
		.flush(0),
		.wready(wbq_wready),
		.wready_two(),         // ← 追加
		.wvalid(wbq_wvalid),
		.wdata(wbq_wdata),
		.rready(wbq_rready),
		.rvalid(wbq_rvalid),
		.rdata(wbq_rdata)
	);


endmodule : core
