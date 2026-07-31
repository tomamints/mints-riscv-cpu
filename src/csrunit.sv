import eei::*;
import corectrl::*;

module csrunit (
	input  logic clk,
	input  logic rst,
	input  logic valid,
	input  Addr  pc,
	input  Inst  inst_bits,
	input  InstCtrl ctrl,
	input  ExceptionInfo expt_info,
	input  logic [4:0]  rd_addr,
	input  logic [11:0] csr_addr,
	input  logic [4:0]  rs1_addr,
	input  UIntX rs1_data,
	input  logic can_intr,
	output UIntX rdata,
	output PrivMode mode,
	output logic raise_trap,
	output Addr  trap_vector,
	output logic trap_return,
	output PrivMode mem_priv_mode,
	output logic minstret_wen,
	output UInt64 minstret_wdata,
	output UIntX pmpcfg0_value,
	output UIntX pmpaddr0_value,
	output UIntX pmpaddr1_value,
	output UIntX pmpaddr2_value,
	output UIntX pmpaddr3_value,
	output UIntX pmpaddr4_value,
	output UIntX pmpaddr5_value,
	output UIntX pmpaddr6_value,
	output UIntX pmpaddr7_value,
	output UIntX satp_value,
	output logic sstatus_sum,
	output logic sstatus_mxr,
	input  UInt64  minstret,
	input  logic external_meip,
	input  logic external_seip,
	aclint_if.slave aclint
);

//WMASK determines which bit can change or not. WARL can write anything but read legal.
	localparam UIntX MSTATUS_WMASK = UIntX'('h0000_0000_007e_19aa) ;
	localparam UIntX MTVEC_WMASK  = 'hffff_ffff_ffff_fffd; //MTVECは[1:0]はMODE設定
	localparam UIntX MEDELEG_WMASK  = 'hffff_ffff_ffff_f7ff;
	localparam UIntX MIDELEG_WMASK  = UIntX'('h0000_0000_0000_0222);
	localparam UIntX MCOUNTEREN_WMASK  = UIntX'('h0000_0000_0000_0007);
	localparam UIntX MSCRATCH_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX MEPC_WMASK   = 'hffff_ffff_ffff_fffe;
	localparam UIntX MCAUSE_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX MTVAL_WMASK  = 'hffff_ffff_ffff_ffff;
	localparam UIntX MIP_WMASK  = UIntX'('h0000_0000_0000_0222);
	localparam UIntX MIE_WMASK  = UIntX'('h0000_0000_0000_0aaa);
	localparam UIntX MCYCLE_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX MINSTRET_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX SSTATUS_WMASK  = UIntX'('h0000_0000_000c_0122);
	localparam UIntX SIP_WMASK      = UIntX'('h0000_0000_0000_0222);
	localparam UIntX SIE_WMASK      = UIntX'('h0000_0000_0000_0222);
	localparam UIntX SCOUNTEREN_WMASK  = UIntX'('h0000_0000_0000_0007);
	localparam UIntX STVEC_WMASK  = 'hffff_ffff_ffff_fffd;
	localparam UIntX SSCRATCH_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX SEPC_WMASK   = 'hffff_ffff_ffff_fffe;
	localparam UIntX SCAUSE_WMASK = 'hffff_ffff_ffff_ffff;
	localparam UIntX STVAL_WMASK  = 'hffff_ffff_ffff_ffff;
	localparam UIntX SATP_WMASK   = 'hffff_ffff_ffff_ffff;
	localparam logic [3:0] SATP_MODE_BARE = 4'd0;
	localparam logic [3:0] SATP_MODE_SV39 = 4'd8;


	//read masks
	localparam UIntX SSTATUS_RMASK  = UIntX'('h8000_0003_018f_e762);


	//CSRR(W|S|C)かどうか
	logic is_wsc;
	assign is_wsc = ctrl.is_csr && ctrl.funct3[1:0] != 0;

	logic [4:0] csr_rs1_addr;
	assign csr_rs1_addr = inst_bits[19:15];

	logic is_mret;
	assign is_mret = (inst_bits == 32'h30200073);

	logic is_sret;
	assign is_sret = (inst_bits == 32'h10200073);

	logic is_wfi;
	assign is_wfi = (inst_bits == 32'h10500073);

	logic is_sfence_vma;
	assign is_sfence_vma = inst_bits[6:0] == OP_SYSTEM &&
	                       inst_bits[14:12] == 3'b000 &&
	                       inst_bits[31:25] == 7'b0001001;

	// will_not_write_csr: CSRRSI / CSRRCI で rs1=0 のとき → 読み取り専用動作
	logic will_not_write_csr;
	assign will_not_write_csr =
		((ctrl.funct3[1:0] == 2'b10) || (ctrl.funct3[1:0] == 2'b11))
		&& (csr_rs1_addr == 5'd0);

	logic csr_write_en;
	assign csr_write_en = is_wsc && !will_not_write_csr;

	logic csr_implemented;
	assign csr_implemented = csr_is_implemented(csr_addr);

	logic expt_unimplemented_csr;
	assign expt_unimplemented_csr = ctrl.is_csr && !csr_implemented;

	// expt_write_readonly_csr: 書き込み系で、書き込み禁止CSRにアクセスしたとき
	logic expt_write_readonly_csr;
	assign expt_write_readonly_csr =
		(is_wsc && !will_not_write_csr && (csr_addr[11:10] == 2'b11));

	logic expt_csr_priv_violation;
	assign expt_csr_priv_violation = is_wsc && (csr_addr[9:8] > mode);

	logic expt_zicntr_priv;
	logic zicntr_denied_S;
	assign zicntr_denied_S =
		(csr_addr == CYCLE)   ? !mcounteren[0] :
		(csr_addr == TIME)    ? !mcounteren[1] :
		(csr_addr == INSTRET) ? !mcounteren[2] :
										1'b0;

	logic zicntr_denied_U =
		(csr_addr == CYCLE)   ? !scounteren[0] :
		(csr_addr == TIME)    ? !scounteren[1] :
		(csr_addr == INSTRET) ? !scounteren[2] :
										1'b0;

	assign expt_zicntr_priv =
		is_wsc &&
		((mode == S && zicntr_denied_S) ||
		 (mode == U && (zicntr_denied_S || zicntr_denied_U)));

	logic expt_trap_return_priv;
	assign expt_trap_return_priv = (is_mret && mode < M) || (is_sret && (mode < S || (mode == S && mstatus_tsr)));
	//attempt to execute trap return instruction in low privilege level

	logic expt_tvm_priv;
	assign expt_tvm_priv = mode == S && mstatus_tvm && (is_sfence_vma || (ctrl.is_csr && csr_addr == SATP));

	//CSR register create
	UIntX misa;
	assign misa = {
    2'd2,                                         // MISAの最上位2ビット (MISA[XLEN-1:XLEN-2])
    1'b0,                                         // 次の1ビット
    {(XLEN - 2 - 1 - 26){1'b0}},                  // 'repeat XLEN - 28' に相当する0ビットの繰り返し
                                                  // (XLEN - 28) = XLEN - (2 + 1 + 25) ではなく、
                                                  // XLEN - (2 + 1 + 26) = XLEN - 29 が正しいため、
                                                  // XLEN - 2 - 1 - 26 = XLEN - 29 で計算します。
    26'b00000101000001000100000101                // MISAの最下位26ビット
	};

	UIntX mhartid = 0;
	UIntX mstatus, mtvec, mideleg, mie, mip, mip_reg, mscratch, mepc, mcause, mtval;
	UIntX pmpcfg0, pmpaddr0, pmpaddr1, pmpaddr2, pmpaddr3, pmpaddr4, pmpaddr5, pmpaddr6, pmpaddr7;
	UIntX satp;
	UInt32 mcounteren;
	UInt64 mcycle, medeleg;
	logic [2:0] trace_post_timer_count;
	logic trace_timer_active;
	UInt64 trace_post_timer_last_minstret;
	UInt64 trace_timer_start_minstret;

	initial begin
		if (!$value$plusargs("TRACE_TIMER_MINSTRET=%h", trace_timer_start_minstret)) begin
			trace_timer_start_minstret = '0;
		end
	end

	assign pmpcfg0_value = pmpcfg0;
	assign pmpaddr0_value = pmpaddr0;
	assign pmpaddr1_value = pmpaddr1;
	assign pmpaddr2_value = pmpaddr2;
	assign pmpaddr3_value = pmpaddr3;
	assign pmpaddr4_value = pmpaddr4;
	assign pmpaddr5_value = pmpaddr5;
	assign pmpaddr6_value = pmpaddr6;
	assign pmpaddr7_value = pmpaddr7;
	assign satp_value = satp;
	assign sstatus_sum = mstatus[18];
	assign sstatus_mxr = mstatus[19];

	assign mip = mip_reg | {
		{(XLEN - 12){1'b0}},
		external_meip, // MEIP
		1'b0, // 0
		external_seip, // SEIP
		1'b0, // 0
		aclint.mtip, // MTIP
		1'b0, // 0
		1'b0, // STIP is held in mip_reg
		1'b0, // 0
		aclint.msip, //MSIP
		1'b0, // 0
		1'b0, // SSIP
		1'b0 // 0
	};



	//mstatus bits

	logic mstatus_tsr;
	assign mstatus_tsr = mstatus[22];

	logic mstatus_tvm;
	assign mstatus_tvm = mstatus[20];

	logic mstatus_mprv;
	assign mstatus_mprv = mstatus[17];

	PrivMode mstatus_mpp;
	assign mstatus_mpp = PrivMode'(mstatus[12:11]);
	assign mem_priv_mode = (mode == M && mstatus_mprv) ? mstatus_mpp : mode;

	PrivMode mstatus_spp;
	assign mstatus_spp = (mstatus[8]) ? S : U;

	logic mstatus_mpie;
	assign mstatus_mpie = mstatus[7];

	logic mstatus_mie;
	assign mstatus_mie = mstatus[3];

	logic mstatus_sie;
	assign mstatus_sie = mstatus[1];

	//Supevisor mode CSR
	UIntX  sstatus , stvec, sscratch, sip, sie, sepc, scause, stval;
	assign sstatus = mstatus & SSTATUS_RMASK;
	UInt32 scounteren;

	assign sip = mip & mideleg;

	//Interrupt to M-mode
	UIntX interrupt_pending_mmode;
	assign interrupt_pending_mmode = mip & mie & ~mideleg;
	logic raise_interrupt_mmode;
	assign raise_interrupt_mmode = (mode != M || mstatus_mie) && interrupt_pending_mmode != 0;

	UIntX interrupt_cause_mmode;
	assign interrupt_cause_mmode =
		interrupt_pending_mmode[11] ? MACHINE_EXTERNAL_INTERRUPT :
		interrupt_pending_mmode[3] ? MACHINE_SOFTWARE_INTERRUPT :
		interrupt_pending_mmode[7] ? MACHINE_TIMER_INTERRUPT :
		interrupt_pending_mmode[9] ? SUPERVISOR_EXTERNAL_INTERRUPT :
		interrupt_pending_mmode[1] ? SUPERVISOR_SOFTWARE_INTERRUPT :
		interrupt_pending_mmode[5] ? SUPERVISOR_TIMER_INTERRUPT :
							UIntX'(0);

	//Interrupt to S-mode
	UIntX interrupt_pending_smode;
	assign interrupt_pending_smode = sip & sie;
	logic raise_interrupt_smode;
	assign raise_interrupt_smode = (mode < S || (mode == S && mstatus_sie)) && interrupt_pending_smode != 0;

	UIntX interrupt_cause_smode;
	assign interrupt_cause_smode =
		interrupt_pending_smode[9] ? SUPERVISOR_EXTERNAL_INTERRUPT :
		interrupt_pending_smode[1] ? SUPERVISOR_SOFTWARE_INTERRUPT :
		interrupt_pending_smode[5] ? SUPERVISOR_TIMER_INTERRUPT :
							UIntX'(0);


		//Interrupt
	logic raise_interrupt;
	assign raise_interrupt = valid && can_intr && (raise_interrupt_mmode || raise_interrupt_smode);

	UIntX interrupt_cause;
	assign interrupt_cause = (raise_interrupt_mmode) ? interrupt_cause_mmode : interrupt_cause_smode;

	Addr interrupt_xtvec;
	assign interrupt_xtvec = (interrupt_mode == M) ? mtvec: stvec;

	Addr interrupt_vector;
	assign interrupt_vector = (interrupt_xtvec[0] == 0) ? {interrupt_xtvec[XLEN-1 : 2], 2'b0} : { (interrupt_xtvec[XLEN-1:2] + interrupt_cause[XLEN-1-2:0]),2'b0}; //vectored

	PrivMode interrupt_mode;
	assign interrupt_mode = (raise_interrupt_mmode) ? M : S ;

	//Exception
	logic raise_expt;
	assign raise_expt = valid && (expt_info.valid || expt_unimplemented_csr || expt_write_readonly_csr || expt_csr_priv_violation || expt_zicntr_priv || expt_trap_return_priv || expt_tvm_priv);
	UIntX expt_cause ;
	always_comb begin
		if(expt_info.valid) begin
			expt_cause = expt_info.cause;
		end else if (expt_unimplemented_csr) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else if (expt_write_readonly_csr) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else if (expt_csr_priv_violation) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else if (expt_zicntr_priv) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else if (expt_trap_return_priv) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else if (expt_tvm_priv) begin
			expt_cause = ILLEGAL_INSTRUCTION;
		end else begin
			expt_cause = '0;
		end
	end

	UIntX expt_value;
	always_comb begin
		if (expt_info.valid)begin
			expt_value = expt_info.value;
		end else if (expt_cause == ILLEGAL_INSTRUCTION) begin
			expt_value = { {(XLEN - $bits(Inst)){1'b0}}, inst_bits };
		end else begin
			expt_value = '0;
		end
	end

	Addr expt_xtvec;
	assign expt_xtvec = (expt_mode == M) ? mtvec : stvec;

	Addr expt_vector;
	assign expt_vector = {expt_xtvec[XLEN-1 : 2], 2'b0};

	PrivMode expt_mode;
	assign expt_mode = (mode == M || !medeleg[expt_cause[5:0]]) ? M : S;

	// Trap Return
	assign trap_return = valid && (is_mret || is_sret) && !raise_expt && !raise_interrupt;
	PrivMode trap_return_mode;
	assign trap_return_mode = (is_mret) ? mstatus_mpp : mstatus_spp;
	Addr trap_return_vector ;
	assign trap_return_vector = (is_mret) ? mepc : sepc;


	//Trap
	assign raise_trap  = raise_expt || raise_interrupt || trap_return;

	UIntX  trap_cause ;
	assign trap_cause =
    raise_expt      ? expt_cause :
    raise_interrupt ? interrupt_cause :
                      UIntX'(0);

	assign trap_vector =
		raise_expt      ? expt_vector :
		raise_interrupt ? interrupt_vector :
		trap_return     ? trap_return_vector :
						UIntX'(0);

	PrivMode trap_mode_next;
	assign trap_mode_next =
		raise_expt      ? expt_mode :
		raise_interrupt ? interrupt_mode :
		trap_return     ? trap_return_mode :
						  U;   // enum名は環境に合わせて



	UIntX wdata;
	UIntX wmask;
	UInt64 minstret_next;

	logic [XLEN-1:0] wsource; //always_comb の外で定義

	always_comb begin
		// read
		case (csr_addr)
			MVENDORID: rdata = '0;
			MARCHID : rdata = '0;
			MISA    : rdata = misa;
			MIMPID  : rdata = MACHINE_IMPLEMENTATION_ID;
			MHARTID : rdata = mhartid;
			MSTATUS : rdata = mstatus;
			MTVEC   : rdata = mtvec;
			MEDELEG   : rdata = medeleg;
			MIDELEG   : rdata = mideleg;
			MIP   : rdata = mip;
			MIE   : rdata = mie;
			MCOUNTEREN   : rdata = {{(XLEN-32){1'b0}},mcounteren};
			PMPCFG0 : rdata = pmpcfg0;
			PMPADDR0 : rdata = pmpaddr0;
			PMPADDR1 : rdata = pmpaddr1;
			PMPADDR2 : rdata = pmpaddr2;
			PMPADDR3 : rdata = pmpaddr3;
			PMPADDR4 : rdata = pmpaddr4;
			PMPADDR5 : rdata = pmpaddr5;
			PMPADDR6 : rdata = pmpaddr6;
			PMPADDR7 : rdata = pmpaddr7;
			MCYCLE  : rdata = mcycle;
			MINSTRET: rdata = minstret;
			MSCRATCH: rdata = mscratch;
			MEPC    : rdata = mepc;
			MCAUSE  : rdata = mcause;
			MTVAL   : rdata = mtval;
			SSTATUS   : rdata = sstatus;
			SCOUNTEREN : rdata = {{(XLEN - 32){1'b0}}, scounteren};
			STVEC   : rdata = stvec;
			SSCRATCH : rdata = sscratch;
			SEPC    : rdata = sepc;
			SCAUSE  : rdata = scause;
			STVAL   : rdata = stval;
			SIP     : rdata = sip;
			SIE     : rdata = sie & mideleg;
			SATP    : rdata = satp;
			CYCLE   : rdata = mcycle;
			TIME    : rdata = aclint.mtime;
			INSTRET : rdata = minstret;
			default       : rdata = '0;
		endcase

		// write mask
		case (csr_addr)
			MSTATUS  : wmask = MSTATUS_WMASK;
			MTVEC    : wmask = MTVEC_WMASK;
			MEDELEG    : wmask = MEDELEG_WMASK;
			MIDELEG    : wmask = MIDELEG_WMASK;
				MIP      : wmask = MIP_WMASK;
				MIE      : wmask = MIE_WMASK;
				MCYCLE   : wmask = MCYCLE_WMASK;
				MINSTRET : wmask = MINSTRET_WMASK;
				MCOUNTEREN : wmask = MCOUNTEREN_WMASK;
			PMPCFG0 : wmask = PMPCFG0_WMASK;
			PMPADDR0 : wmask = PMPADDR_WMASK;
			PMPADDR1 : wmask = PMPADDR_WMASK;
			PMPADDR2 : wmask = PMPADDR_WMASK;
			PMPADDR3 : wmask = PMPADDR_WMASK;
			PMPADDR4 : wmask = PMPADDR_WMASK;
			PMPADDR5 : wmask = PMPADDR_WMASK;
			PMPADDR6 : wmask = PMPADDR_WMASK;
			PMPADDR7 : wmask = PMPADDR_WMASK;
			MSCRATCH : wmask = MSCRATCH_WMASK;
			MEPC     : wmask = MEPC_WMASK;
			MCAUSE   : wmask = MCAUSE_WMASK;
			MTVAL    : wmask = MTVAL_WMASK;
			SSTATUS  : wmask = SSTATUS_WMASK;
			SCOUNTEREN : wmask = SCOUNTEREN_WMASK;
			STVEC : wmask = STVEC_WMASK;
			SSCRATCH : wmask = SSCRATCH_WMASK;
			SEPC : wmask = SEPC_WMASK;
			SCAUSE : wmask = SCAUSE_WMASK;
			STVAL : wmask = STVAL_WMASK;
			SIP : wmask = SIP_WMASK & mideleg;
			SIE : wmask = SIE_WMASK & mideleg;
			SATP : wmask = SATP_WMASK;
			default       : wmask = '0;
		endcase

		// wsource
		// (funct3[2] == 1 : immediate → inst[19:15] is used as zimm)
		if (ctrl.funct3[2]) begin
			wsource = {{(XLEN-5){1'b0}}, csr_rs1_addr};
		end else begin
			wsource = rs1_data;
		end

		// wdata (CSRRS, CSRRC, etc.)
		case (ctrl.funct3[1:0])
			2'b01:  wdata = wsource;            // CSRRW / CSRRWI
			2'b10:  wdata = rdata | wsource;    // CSRRS / CSRRSI
			2'b11:  wdata = rdata & ~wsource;   // CSRRC / CSRRCI
			default: wdata = 'x;
		endcase

		// apply write mask
		wdata = (wdata & wmask) | (rdata & ~wmask);
		minstret_next = UInt64'(wdata);
	end

	assign minstret_wen = valid && csr_write_en && !raise_trap && csr_addr == MINSTRET;
	assign minstret_wdata = minstret_next;

	UIntX setssip;
	assign setssip = {{(XLEN - 2){1'b0}}, aclint.setssip, 1'b0 };
	UIntX setstip;
	assign setstip = {{(XLEN - 6){1'b0}}, aclint.setstip, 5'b0 };
	UIntX set_s_interrupt_pending;
	assign set_s_interrupt_pending = setssip | setstip;

	Addr xepc;

	//WARL: Write Any Read Legal対応
	function automatic UIntX validate_satp(
		input UIntX current,
		input UIntX value
	);
		unique case (value[63:60])
			SATP_MODE_BARE: validate_satp = '0;
			SATP_MODE_SV39: validate_satp = value;
			default:        validate_satp = current;
		endcase
	endfunction

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			mode     <=  M;
			mstatus  <=  MSTATUS_UXL | MSTATUS_SXL;
			mtvec    <= '0;
			medeleg    <= '0;
			mideleg    <= '0;
			mie      <= '0;
			mip_reg  <= '0;
			pmpcfg0  <= '0;
			pmpaddr0 <= '0;
			pmpaddr1 <= '0;
			pmpaddr2 <= '0;
			pmpaddr3 <= '0;
			pmpaddr4 <= '0;
			pmpaddr5 <= '0;
			pmpaddr6 <= '0;
			pmpaddr7 <= '0;
			satp <= '0;
			mcounteren <= '0;
			mscratch <= '0;
			mcycle   <= '0;
			mepc     <= '0;
			mcause   <= '0;
			mtval    <= '0;
			scounteren <= '0;
			stvec <= '0;
			sscratch <= '0;
			sepc <= '0;
			scause <= '0;
			stval <= '0;
			sie <= '0;
			trace_post_timer_count <= '0;
			trace_timer_active <= 1'b0;
			trace_post_timer_last_minstret <= '0;
		end else begin
			mcycle += 1;
			mip_reg |= set_s_interrupt_pending;
			if (valid) begin
				if ($test$plusargs("TRACE_TIMER_IRQ") &&
					minstret >= trace_timer_start_minstret &&
					trace_post_timer_count != 0 &&
					minstret != trace_post_timer_last_minstret &&
					!raise_trap) begin
					$display("[TIMER-POST] minstret=%h pc=%h inst=%h mode=%0d mtime=%h mtip=%0b mip=%h mip_reg=%h sip=%h mstatus=%h count=%0d",
						minstret,
						pc,
						inst_bits,
						mode,
						aclint.mtime,
						aclint.mtip,
						mip,
						mip_reg,
						sip,
						mstatus,
						trace_post_timer_count);
					trace_post_timer_count <= trace_post_timer_count - 1'b1;
					trace_post_timer_last_minstret <= minstret;
				end
				if (raise_trap) begin
					if ($test$plusargs("TRACE_TRAP")) begin
						$display("[TRAP] pc=%h inst=%h mode=%0d expt=%b intr=%b ret=%b cause=%h tval=%h vector=%h next_mode=%0d satp=%h stvec=%h mtvec=%h",
							pc,
							inst_bits,
							mode,
							raise_expt,
							raise_interrupt,
							trap_return,
							trap_cause,
							expt_value,
							trap_vector,
							trap_mode_next,
							satp,
							stvec,
							mtvec);
					end
					if ($test$plusargs("TRACE_TIMER_IRQ") &&
						minstret >= trace_timer_start_minstret &&
						raise_interrupt &&
						(trap_cause == SUPERVISOR_TIMER_INTERRUPT || trap_cause == MACHINE_TIMER_INTERRUPT)) begin
						$display("[TIMER-ENTRY] pc=%h mode=%0d cause=%h vector=%h next_mode=%0d mtime=%h mtip=%0b mip=%h mip_reg=%h sip=%h mstatus=%h",
							pc,
							mode,
							trap_cause,
							trap_vector,
							trap_mode_next,
							aclint.mtime,
							aclint.mtip,
							mip,
							mip_reg,
							sip,
							mstatus);
					end
					if (raise_expt || raise_interrupt) begin
						if (raise_interrupt &&
							(trap_cause == SUPERVISOR_TIMER_INTERRUPT || trap_cause == MACHINE_TIMER_INTERRUPT)) begin
							trace_timer_active <= 1'b1;
						end
						if (raise_expt)begin
							xepc = pc; //exception
						end else if (raise_interrupt && is_wfi) begin
							xepc = pc + 4;
						end else begin
							xepc = pc;
						end
						if (trap_mode_next == M) begin
							mepc <= xepc;
							mcause <= trap_cause;
							if (raise_expt) begin
								mtval <= expt_value;
							end
							//save mstatus.mie to mstatus.mpie
							//and set mstatus.mie = 0
							mstatus[7] <= mstatus[3];
							mstatus[3] <= 0;
							//save current priviledge level to mstatus.mpp
							mstatus[12:11] <= mode;
						end else begin
							sepc <= xepc;
							scause <= trap_cause;
							if (raise_expt) begin
								stval <= expt_value;
							end
							//save sstatus.sie to sstatus.spie
							//and set sstatus.sie = 0
							mstatus[5] <= mstatus[1];
							mstatus[1] <= 0;
							//save current privilege mode (S or U) to sstatus.spp
							mstatus[8] <= mode[0];
						end
					end else if (trap_return) begin
						if ($test$plusargs("TRACE_TIMER_IRQ") &&
							minstret >= trace_timer_start_minstret &&
							trace_timer_active) begin
							$display("[TIMER-RETURN] pc=%h mode=%0d sret=%0b mret=%0b vector=%h next_mode=%0d mtime=%h mtip=%0b mip=%h mip_reg=%h sip=%h mstatus=%h",
								pc,
								mode,
								is_sret,
								is_mret,
								trap_vector,
								trap_mode_next,
								aclint.mtime,
								aclint.mtip,
								mip,
								mip_reg,
								sip,
								mstatus);
						end
						if (is_mret) begin
							//save mstatus.mie to mstatus.mipe
							// and set mstatus.mie = 0
							mstatus[3] <= mstatus[7];
							mstatus[7] <= 0;
							// set mstatus.mpp = U (least priviledge level)
							mstatus[12:11] <= U;
						end else if (is_sret) begin
							//set sstatus.sie = sstatus.spie
							//    sstatus.spie = 0
							mstatus[1] <= mstatus[5];
							mstatus[5] <= 0;
							//set sstatus.spp <= U
							mstatus[8] <= 0;
						end
						if (trace_timer_active) begin
							trace_post_timer_count <= 3'd4;
							trace_post_timer_last_minstret <= minstret;
							trace_timer_active <= 1'b0;
						end
					end
					mode <= trap_mode_next;
				end else begin
					if (csr_write_en) begin
						if ($test$plusargs("TRACE_CSR") && (
							csr_addr == MSTATUS ||
							csr_addr == SSTATUS ||
							csr_addr == MTVEC ||
							csr_addr == STVEC ||
							csr_addr == MEDELEG ||
							csr_addr == MIDELEG ||
							csr_addr == MIE ||
							csr_addr == SIE ||
							csr_addr == MIP ||
							csr_addr == SIP ||
							csr_addr == SATP
						)) begin
							$display("[CSR] pc=%h mode=%0d csr=%03h old=%h new=%h inst=%h",
								pc,
								mode,
								csr_addr,
								rdata,
								(csr_addr == SATP) ? validate_satp(satp, wdata) : wdata,
								inst_bits);
						end
						if ($test$plusargs("TRACE_TIMER_IRQ") &&
							minstret >= trace_timer_start_minstret &&
							(csr_addr == SIP || csr_addr == MIP) &&
							(rdata[5] != wdata[5] || aclint.setstip)) begin
							$display("[TIMER-CSR] pc=%h mode=%0d csr=%03h old=%h new=%h mtime=%h mtip=%0b mip=%h mip_reg=%h sip=%h setstip=%0b",
								pc,
								mode,
								csr_addr,
								rdata,
								wdata,
								aclint.mtime,
								aclint.mtip,
								mip,
								mip_reg,
								sip,
								aclint.setstip);
						end
						case (csr_addr) //これらはそれぞれのCSRレジスタにwdataを入れている。
							MSTATUS  : mstatus  <= validate_mstatus(mstatus, wdata);
							MTVEC    : mtvec    <= wdata;
							MEDELEG    : medeleg    <= wdata;
							MIDELEG   : mideleg    <= wdata;
								MIP      : mip_reg    <= (wdata & MIP_WMASK) | set_s_interrupt_pending;
								MIE      : mie      <= wdata & MIE_WMASK;
								MCYCLE   : mcycle   <= wdata;
								MCOUNTEREN : mcounteren <= wdata[31:0];
							PMPCFG0 : pmpcfg0 <= wdata & PMPCFG0_WMASK;
							PMPADDR0 : pmpaddr0 <= wdata & PMPADDR_WMASK;
							PMPADDR1 : pmpaddr1 <= wdata & PMPADDR_WMASK;
							PMPADDR2 : pmpaddr2 <= wdata & PMPADDR_WMASK;
							PMPADDR3 : pmpaddr3 <= wdata & PMPADDR_WMASK;
							PMPADDR4 : pmpaddr4 <= wdata & PMPADDR_WMASK;
							PMPADDR5 : pmpaddr5 <= wdata & PMPADDR_WMASK;
							PMPADDR6 : pmpaddr6 <= wdata & PMPADDR_WMASK;
							PMPADDR7 : pmpaddr7 <= wdata & PMPADDR_WMASK;
							MSCRATCH : mscratch <= wdata;
							MEPC     : mepc     <= wdata;
							MCAUSE   : mcause   <= wdata;
							MTVAL    : mtval    <= wdata;
							SSTATUS  : mstatus  <= validate_mstatus(mstatus, wdata | mstatus & ~SSTATUS_WMASK);
							SCOUNTEREN : scounteren <= wdata[31:0];
							STVEC : stvec <= wdata;
							SSCRATCH : sscratch <= wdata;
							SEPC : sepc <= wdata;
							SCAUSE : scause <= wdata;
							STVAL : stval <= wdata;
							SIP : mip_reg <= (mip_reg & ~(SIP_WMASK & mideleg)) | (wdata & (SIP_WMASK & mideleg)) | set_s_interrupt_pending;
							SIE : sie <= wdata;
							SATP : satp <= validate_satp(satp, wdata);
							default  : /* do nothing */ ;
						endcase
					end
				end
			end
		end
	end
	function automatic UIntX validate_mstatus(
		input UIntX mstatus,
		input UIntX wdata
	);
		UIntX result;
		result = wdata;

		// MPP: only M(11) or U(00) allowed
		if (wdata[12:11] == 2'b10)
		begin
			result[12:11] = mstatus[12:11];
		end

		return result;
	endfunction

	function automatic logic csr_is_implemented(
		input logic [11:0] addr
	);
		case (addr)
			MVENDORID,
			MARCHID,
			MIMPID,
			MHARTID,
			MSTATUS,
			MISA,
			MEDELEG,
			MIDELEG,
			MIE,
			MTVEC,
			MCOUNTEREN,
			PMPCFG0,
			PMPADDR0,
			PMPADDR1,
			PMPADDR2,
			PMPADDR3,
			PMPADDR4,
			PMPADDR5,
			PMPADDR6,
			PMPADDR7,
			MSCRATCH,
			MEPC,
			MCAUSE,
			MTVAL,
			MIP,
			MCYCLE,
			MINSTRET,
			SSTATUS,
			SIE,
			STVEC,
			SCOUNTEREN,
			SSCRATCH,
			SEPC,
			SCAUSE,
			STVAL,
			SIP,
			SATP,
			CYCLE,
			TIME,
			INSTRET: csr_is_implemented = 1'b1;
			default: csr_is_implemented = 1'b0;
		endcase
	endfunction
endmodule : csrunit
