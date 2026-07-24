package eei;

	//定数定義
	localparam int unsigned XLEN = 64; //レジスタのながさ
	localparam int unsigned ILEN = 32; //命令の最大幅（今回は32、圧縮は16?）
	localparam int unsigned IALIGN = 16; //C命令

	typedef logic [XLEN-1:0] UIntX;
	typedef logic [31:0]     UInt32;
	typedef logic [63:0]     UInt64;
	typedef logic [ILEN-1:0] Inst;
	typedef logic [XLEN-1:0] Addr;
	typedef logic signed [XLEN-1:0] SIntX;
	typedef logic signed [31:0] SInt32;
	typedef logic signed [63:0] SInt64;

	typedef enum logic [1:0] {
		PMP_ACCESS_READ  = 2'b00,
		PMP_ACCESS_WRITE = 2'b01,
		PMP_ACCESS_EXEC  = 2'b10
	} PmpAccessType;

	localparam UIntX MACHINE_IMPLEMENTATION_ID = 1;
	localparam UIntX PMPCFG0_WMASK = UIntX'('h0000_0000_1f1f_1f1f);
	localparam UIntX PMPADDR_WMASK = UIntX'('h003f_ffff_ffff_ffff);

	localparam UInt64 MSTATUS_UXL = 2 << 32;
	localparam UInt64 MSTATUS_SXL = 2 << 34;

	// memory bus data
	localparam int MEMBUS_DATA_WIDTH = 64;

	//RAM
	localparam int RAM_ADDR_WIDTH = 16;
	localparam int RAM_DATA_WIDTH = 64;
	localparam Addr MMAP_RAM_BEGIN = Addr'('h8000_0000);

	//ROM
	localparam int ROM_ADDR_WIDTH = 9;
	localparam int ROM_DATA_WIDTH = 64;
	localparam Addr MMAP_ROM_BEGIN = Addr'('h1000);
	localparam Addr MMAP_ROM_END   = Addr'(MMAP_ROM_BEGIN + 'h3ff);

	//ACLINT
	localparam Addr MMAP_ACLINT_BEGIN = Addr'('h200_0000);
	localparam Addr MMAP_ACLINT_MSIP = 0;
	localparam Addr MMAP_ACLINT_MTIMECMP = Addr'('h4000);
	localparam Addr MMAP_ACLINT_MTIME = Addr'('h7ff8);
	localparam Addr MMAP_ACLINT_SETSSIP = Addr'('h8000);
	localparam Addr MMAP_ACLINT_SETSTIP = Addr'('h8008);
	localparam Addr MMAP_ACLINT_END = MMAP_ACLINT_BEGIN + Addr'('hbfff);

	//DMA
	localparam Addr MMAP_DMA_BEGIN  = Addr'('h3000_0000);
	localparam Addr MMAP_DMA_CTRL   = Addr'('h00); // 32-bitでも64-bitでもOK
	localparam Addr MMAP_DMA_STATUS = Addr'('h08); // ここから8バイト刻み
	localparam Addr MMAP_DMA_SRC    = Addr'('h10); // 64-bit
	localparam Addr MMAP_DMA_DST    = Addr'('h18); // 64-bit
	localparam Addr MMAP_DMA_LEN    = Addr'('h20); // 32-bit (or 64)
	localparam Addr MMAP_DMA_END    = MMAP_DMA_BEGIN + Addr'('h0FFF);


	// reset vector
	localparam Addr INITIAL_PC = MMAP_ROM_BEGIN;

	localparam logic [6:0] OP_LUI       = 7'b0110111;//localparam→上書きできないように
	localparam logic [6:0] OP_AUIPC     = 7'b0010111;
	localparam logic [6:0] OP_OP        = 7'b0110011;
	localparam logic [6:0] OP_OP_IMM    = 7'b0010011;
	localparam logic [6:0] OP_OP_32     = 7'b0111011;
	localparam logic [6:0] OP_OP_IMM_32 = 7'b0011011;
	localparam logic [6:0] OP_JAL       = 7'b1101111;
	localparam logic [6:0] OP_JALR      = 7'b1100111;
	localparam logic [6:0] OP_BRANCH    = 7'b1100011;
	localparam logic [6:0] OP_LOAD      = 7'b0000011;
	localparam logic [6:0] OP_STORE     = 7'b0100011;
	localparam logic [6:0] OP_SYSTEM    = 7'b1110011;
	localparam logic [6:0] OP_MISC_MEM  = 7'b0001111;
	localparam logic [6:0] OP_AMO  = 7'b0101111;


	typedef enum logic [4:0] {
		LR = 5'b00010,
        SC = 5'b00011,
        SWAP = 5'b00001,
        ADD = 5'b00000,
        XOR = 5'b00100,
        AND = 5'b01100,
        OR = 5'b01000,
        MIN = 5'b10000,
        MAX = 5'b10100,
        MINU = 5'b11000,
        MAXU = 5'b11100
	} AMOOp;

	typedef enum logic [1:0] {
		M = 2'b11,
		S = 2'b01,
		U = 2'b00
	} PrivMode;

	typedef enum logic [11:0]{
		// Supervisor Trap Setup
        SSTATUS = 12'h100,
        SIE = 12'h104,
        STVEC = 12'h105,
        SCOUNTEREN = 12'h106,
        // Supervisor Trap Handling
        SSCRATCH = 12'h140,
        SEPC = 12'h141,
        SCAUSE = 12'h142,
        STVAL = 12'h143,
        SIP = 12'h144,
        // Supervisor Protection and Translation
        SATP = 12'h180,
		//Machine Infomation Registers
		MIMPID  = 12'hf13,
		MHARTID = 12'hf14,
		//Machine Trap Setup
		MSTATUS = 12'h300,
		MISA    = 12'h301,
		MEDELEG = 12'h302,
		MIDELEG = 12'h303,
		MIE     = 12'h304,
		MTVEC   = 12'h305,
		MCOUNTEREN = 12'h306,
		PMPCFG0 = 12'h3a0,
		PMPADDR0 = 12'h3b0,
		PMPADDR1 = 12'h3b1,
		PMPADDR2 = 12'h3b2,
		PMPADDR3 = 12'h3b3,
		//Machine Trap Handling
		MSCRATCH = 12'h340,
		MEPC   = 12'h341,
		MCAUSE = 12'h342,
		MTVAL  = 12'h343,
		MIP    = 12'h344,
		// Machine Counter/Timers
		MCYCLE = 12'hB00,
		MINSTRET = 12'hB02,
		//Custom
		LED   = 12'h800,
		//Unpriviledged Counter/Timers
		CYCLE = 12'hC00,
		TIME  = 12'hC01,
		INSTRET = 12'hC02
	} CsrAddr;

	typedef enum UIntX{
		INSTRUCTION_ADDRESS_MISALIGNED = 0,
		INSTRUCTION_ACCESS_FAULT = 1,
		ILLEGAL_INSTRUCTION = 2,
		BREAKPOINT = 3,
		LOAD_ADDRESS_MISALIGNED = 4,
		LOAD_ACCESS_FAULT = 5,
		STORE_AMO_ADDRESS_MISALIGNED = 6,
		STORE_AMO_ACCESS_FAULT = 7,
		ENVIRONMENT_CALL_FROM_U_MODE = 8,
		ENVIRONMENT_CALL_FROM_M_MODE = 11,
		SUPERVISOR_SOFTWARE_INTERRUPT = 'h8000_0000_0000_0001,
        MACHINE_SOFTWARE_INTERRUPT = 'h8000_0000_0000_0003,
        SUPERVISOR_TIMER_INTERRUPT = 'h8000_0000_0000_0005,
        MACHINE_TIMER_INTERRUPT = 'h8000_0000_0000_0007,
        SUPERVISOR_EXTERNAL_INTERRUPT = 'h8000_0000_0000_0009,
        MACHINE_EXTERNAL_INTERRUPT = 'h8000_0000_0000_000b
		} CsrCause;



endpackage : eei
