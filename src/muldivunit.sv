import eei::*;

module muldivunit(
	input  logic      clk  ,
	input  logic      rst  ,
	output logic      ready,
	input  logic      valid,
	input  logic[2:0] funct3,
	input  logic      is_op32,
	input  UIntX      op1,
	input  UIntX      op2,
    output logic      rvalid,
    output UIntX      result
	);

	typedef enum logic[1:0]{
		Idle,
		WaitValid,
		Finish
	}State;

	State state;

	//saed_data
	logic[2:0] funct3_saved;
	logic is_op32_saved ;
	logic op1sign_saved ;
	logic op2sign_saved ;

	function automatic logic [XLEN-1:0] abs (
		input logic signed [XLEN-1:0] value
	);
		if (value[XLEN-1]) begin
			return (~value) + 1'b1;  // ~value + 1
		end else begin
			return value;
		end
	endfunction

	function automatic logic [DIV_WIDTH-1:0] abs_div (
		input logic signed [DIV_WIDTH-1:0] value
	);
		if (value[DIV_WIDTH-1]) begin
			return (~value) + 1'b1;  // ~value + 1
		end else begin
			return value;
		end
	endfunction

	function automatic logic [XLEN-1:0] sext_xlen (
		input logic [31:0] value
	);
		return {{(XLEN-32){value[31]}}, value};
	endfunction

	function automatic logic [63:0] sext_64 (
		input logic [31:0] value
	);
		return {{(64-32){value[31]}}, value};
	endfunction

	//multiply unit
	localparam MUL_OP_WIDTH = XLEN;
	localparam MUL_RES_WIDTH = MUL_OP_WIDTH *2;

	logic is_mul;
	logic mu_rvalid;
	logic [MUL_RES_WIDTH-1:0] mu_result;
	assign is_mul = (state == Idle) ? !funct3[2] : !funct3_saved[2];

	logic [MUL_OP_WIDTH-1:0] mu_op1;
	logic [MUL_OP_WIDTH-1:0] mu_op2;

	always_comb begin
		unique case (funct3[1:0])
			2'b00,
			2'b01,
			2'b10: mu_op1 = abs((is_op32) ? sext_xlen(op1[31:0]) : op1); // MUL, MULH, MULHSU, MULW
			2'b11: mu_op1 = op1;          // MULHU
			default: mu_op1 = '0;
		endcase

		unique case (funct3[1:0])
			2'b00,
			2'b01: mu_op2 = abs((is_op32) ? sext_xlen(op2[31:0]) : op2); // MUL, MULH, MULW
			2'b11,2'b10: mu_op2 = op2;          // MULHU,MULHSU
			default: mu_op2 = '0;
		endcase
	end


	mulunit #(
		.WIDTH(MUL_OP_WIDTH)
	)  mu (
		.clk   (clk),
		.rst   (rst),
		.valid (ready && valid && is_mul),
		.op1   (mu_op1),
		.op2   (mu_op2),
		.rvalid(mu_rvalid),
		.result(mu_result)
	);

	//divider unit

	localparam DIV_WIDTH = XLEN;

	logic du_rvalid;
	logic [DIV_WIDTH-1:0] du_quotient;
	logic [DIV_WIDTH-1:0] du_remainder;

	// DIV / REM 演算用オペランド生成
	function automatic logic [DIV_WIDTH-1:0] generate_div_op (
		input logic              is_op32,
		input logic [2:0]        funct3,
		input logic [XLEN-1:0]   value
	);
		logic [DIV_WIDTH-1:0] val_ext;

		// 32bit演算系の sign-extend / zero-extend
		if (is_op32) begin
			logic [31:0] v32 = value[31:0];
			// 符号拡張（signed）
			val_ext = {{(DIV_WIDTH-32){v32[31]}}, v32};
		end else begin
			val_ext = value;
		end

		// 命令種別で abs or unsigned
		case (funct3[1:0])
			2'b00, 2'b10: begin // DIV, REM (signed)
				if (val_ext[DIV_WIDTH-1] == 1'b1)
					return (~val_ext + 1'b1);  // abs(val_ext)
				else
					return val_ext;
			end
			2'b01, 2'b11: begin // DIVU, REMU (unsigned)
				return val_ext;
			end
			default: return '0;
		endcase
	endfunction

	function automatic logic [DIV_WIDTH-1:0] generate_div_op1 (
		input logic              is_op32,
		input logic [2:0]        funct3,
		input logic [XLEN-1:0]   value
	);
		logic [31:0] v32;
		logic [DIV_WIDTH-1:0] val_ext;

		if (is_op32) begin
			v32 = value[31:0];
			case (funct3[1:0])
				2'b00, 2'b10: // DIVW, REMW (signed W)
					val_ext = {{(DIV_WIDTH-32){v32[31]}}, v32}; // sign-extend
				2'b01, 2'b11: // DIVUW, REMUW (unsigned W)
					val_ext = {{(DIV_WIDTH-32){1'b0}}, v32};    // **zero-extend**
			endcase
		end else begin
			val_ext = value;
		end

		// signed vs unsigned 選択 (ここは現状のままでOK)
		case (funct3[1:0])
			2'b00, 2'b10: return (val_ext[DIV_WIDTH-1]) ? (~val_ext + 1'b1) : val_ext; // signed abs
			2'b01, 2'b11: return val_ext;                                              // unsigned
			default:      return '0;
		endcase
	endfunction



	logic [DIV_WIDTH-1:0] du_dividend;
	assign du_dividend = generate_div_op1(is_op32,funct3, op1);
	logic [DIV_WIDTH-1:0] du_divisor;
	assign du_divisor = generate_div_op1(is_op32,funct3, op2);
	logic du_signed_overflow;
	logic du_signed_divzero;
	logic du_signed_error;

	always_comb begin
		if (is_op32) begin
			// INT_MIN(32bit) = 0x8000_0000
			du_signed_overflow = (!funct3[0]) && (op1[31] == 1'b1) && (op1[31:0] == 32'h8000_0000) && (op2[31:0] == 32'hFFFF_FFFF);
			du_signed_divzero  = (!funct3[0]) && (op2[31:0] == 32'h0000_0000);
		end else begin
			// INT_MIN(XLEN bit)
			du_signed_overflow = (!funct3[0]) && (op1[XLEN-1] == 1'b1) && (op1[XLEN-1:0] == {1'b1, {(XLEN-1){1'b0}}}) && (op2 == {XLEN{1'b1}});
			du_signed_divzero  = (!funct3[0]) && (op2 == {XLEN{1'b0}});
		end

		du_signed_error = du_signed_overflow || du_signed_divzero;
	end



	divunit #(
		.WIDTH(DIV_WIDTH)
	) du (
		.clk(clk),
		.rst(rst),
		.valid(ready && valid && !is_mul && !du_signed_error),
		.dividend(du_dividend),
		.divisor(du_divisor),
		.rvalid(du_rvalid),
		.quotient(du_quotient),
		.remainder(du_remainder)
	);

	always_comb begin
		ready  = state == Idle;
		rvalid = state == Finish;
	end

	always_ff @(posedge clk or negedge rst)begin
		if(!rst)begin
			state         <= Idle;
			result        <= '0;
			funct3_saved  <= '0;
			is_op32_saved <= '0;
			op1sign_saved <= '0;
			op2sign_saved <= '0;
		end else begin
			case (state)
				Idle : begin
					if(ready && valid) begin
						funct3_saved <= funct3;
						is_op32_saved <= is_op32;
						if(is_op32)begin
							op1sign_saved <= op1[31];
							op2sign_saved <= op2[31];
						end else begin
							op1sign_saved <= op1[XLEN-1];
							op2sign_saved <= op2[XLEN-1];
						end
						if(is_mul)begin
							state <= WaitValid;
						end else begin
							if(du_signed_overflow)begin
								state <= Finish;
								if (funct3[1]) begin
									// REM または REMW のオーバーフロー
									result <= '0;
								end else begin
									// DIV または DIVW のオーバーフロー
									if (is_op32) begin
										// DIVW: sext(0x8000_0000)
										result <= sext_64(32'h8000_0000);
									end else begin
										// DIV: 64bit INT_MIN
										result <= {1'b1,{(XLEN-1){1'b0}}};
									end
								end
							end else if (du_signed_divzero)begin
								state <= Finish;
								result <= (funct3[1]) ? op1 : '1;//REM:DIV
							end else begin
								state <= WaitValid;
							end
						end
					end
				end
				WaitValid: begin
					if (is_mul && mu_rvalid) begin
						logic [MUL_RES_WIDTH-1:0] res_signed;
						logic [MUL_RES_WIDTH-1:0] res_mulhsu;
						if (op1sign_saved != op2sign_saved)begin
							res_signed = (~mu_result) + 1'b1; // negate (2's complement)
						end else begin
							res_signed = mu_result;
						end
						if (op1sign_saved == 1)begin
							res_mulhsu = (~mu_result) + 1'b1; // negate (2's complement)
						end else begin
							res_mulhsu = mu_result;
						end
						state <= Finish;
						case (funct3_saved[1:0])
							2'b00:   result <= (is_op32_saved) ? sext_64(res_signed[31:0]) : res_signed[XLEN-1:0];//MUL
							2'b01:   result <= res_signed[XLEN+:XLEN];//MULH
							2'b10:   result <= res_mulhsu[XLEN+:XLEN];//MULH
							2'b11:   result <= mu_result[XLEN+:XLEN]; //MULHU
							default: result <= '0;
						endcase
					end else if(!is_mul && du_rvalid) begin
						logic [DIV_WIDTH-1:0] quo_signed;
						logic [DIV_WIDTH-1:0] rem_signed;
						UIntX resultX;
						quo_signed = (op1sign_saved != op2sign_saved) ? (~du_quotient + 1'b1) : du_quotient;
						rem_signed = (op1sign_saved == 1'b1) ? (~du_remainder + 1'b1) : du_remainder;
						case (funct3_saved[1:0])
							2'b00: resultX = quo_signed[XLEN - 1:0]; //DIV
							2'b01: resultX = du_quotient[XLEN -1:0]; //DIVU
							2'b10: resultX = rem_signed[XLEN - 1:0]; //REM
							2'b11: resultX = du_remainder[XLEN -1:0];//REMU
							default : resultX <= '0;
						endcase
						state <= Finish;
						result <= (is_op32_saved) ? sext_64(resultX[31:0]) : resultX;
					end
				end
			    Finish    : state <= Idle;
				default : ;
			endcase
		end
	end
endmodule : muldivunit

module mulunit #(
    parameter WIDTH = 0
)(
    input  logic                  clk,
    input  logic                  rst,
    input  logic                  valid,
    input  logic [WIDTH-1:0]      op1,
    input  logic [WIDTH-1:0]      op2,
    output logic                  rvalid,
    output logic [(WIDTH*2)-1:0]  result
);

    // enum
    typedef enum logic [1:0] {
        Idle,
        AddLoop,
        Finish
    } State;

    State state;

    logic [(WIDTH*2)-1:0] op1zext;
    logic [(WIDTH*2)-1:0] op2zext;

    assign rvalid = (state == Finish);

    integer add_count;

`ifdef PRINT_DEBUG
	always_ff @(posedge clk)begin
		$display("mulunit_rvalid %b", rvalid);
		$display("mulunit_result %d", result);
		$display("mulunit_state %d" , state);
		$display("mulunit_op1 %d",op1);
		$display("mulunit_op2 %d",op2);
		$display("mulunit_add_count %d",add_count);
	end
`endif

	always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            state     <= Idle;
            result    <= '0;
            add_count <= 0;
            op1zext   <= '0;
            op2zext   <= '0;
        end else begin
            case (state)
                Idle: begin
                    if (valid) begin
                        state     <= AddLoop;
                        result    <= '0;
                        add_count <= 0;
                        op1zext   <= {{WIDTH{1'b0}}, op1};
                        op2zext   <= {{WIDTH{1'b0}}, op2};
                    end
                end

                AddLoop: begin
                    if (add_count == WIDTH) begin
                        state <= Finish;
                    end else begin
                        if (op2zext[add_count])
                            result <= result + op1zext;
                        op1zext   <= op1zext << 1;
                        add_count <= add_count + 1;
                    end
				end

                Finish: begin
                    state <= Idle;
                end
				default: ;
            endcase
        end
    end
endmodule


module divunit #(
    parameter int WIDTH = 0
) (
    input  logic                 clk,
    input  logic                 rst,
    input  logic                 valid,
    input  logic [WIDTH-1:0]     dividend,
    input  logic [WIDTH-1:0]     divisor,
    output logic                 rvalid,
    output logic [WIDTH-1:0]     quotient,
    output logic [WIDTH-1:0]     remainder
);

    // 状態定義
    typedef enum logic [1:0] {
        Idle,
        ZeroCheck,
        SubLoop,
        Finish
    } State;

    State state;

    // 内部レジスタ
    logic [WIDTH*2-1:0] dividend_saved;
    logic [WIDTH*2-1:0] divisor_saved;
    logic [$clog2(WIDTH+1)-1:0] sub_count;

    // 出力生成（組 combinational）
    always_comb begin
        rvalid    = (state == Finish);
        remainder = dividend_saved[WIDTH-1:0];
    end

    // 状態遷移・演算本体
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            state          <= Idle;
            quotient       <= '0;
            sub_count      <= '0;
            dividend_saved <= '0;
            divisor_saved  <= '0;
        end else begin
            case (state)

                Idle: if (valid) begin
                    state          <= ZeroCheck;
                    dividend_saved <= {{WIDTH{1'b0}}, dividend};               // 上位 WIDTH bit 0 + dividend
                    divisor_saved  <= {1'b0, divisor, {(WIDTH-1){1'b0}}};      // divisor << (WIDTH-1)
                    quotient       <= '0;
                    sub_count      <= '0;
                end

                ZeroCheck: begin
                    if (divisor_saved == '0) begin
                        state    <= Finish;
                        quotient <= '1;     // 全ビット1
                    end else begin
                        state <= SubLoop;
                    end
                end

                SubLoop: begin
                    if (sub_count == WIDTH[$clog2(WIDTH+1)-1:0]) begin
                        state <= Finish;
                    end else begin
                        if (dividend_saved >= divisor_saved) begin
                            dividend_saved <= dividend_saved - divisor_saved;
                            quotient       <= (quotient << 1) | 1;
                        end else begin
                            quotient       <= (quotient << 1);
                        end
                        divisor_saved <= (divisor_saved >> 1);
                        sub_count     <= sub_count + 1;
                    end
                end

                Finish: begin
                    state <= Idle;
                end

                default: state <= Idle;
            endcase
        end
    end
endmodule
