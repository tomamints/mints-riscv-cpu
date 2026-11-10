import eei::*;
import corectrl::*;

module brunit(
	input logic[2:0] funct3,
	input UIntX op1,
	input UIntX op2,
	output logic take
	);

	logic beq;

	assign beq = op1 == op2;
	logic blt;
	assign blt = $signed(op1) < $signed(op2);
	logic bltu;
	assign bltu = op1 < op2;

	always_comb begin
		case (funct3)
			3'b000 : take = beq;
			3'b001 : take = !beq;
			3'b100 : take = blt;
			3'b101 : take = !blt;
			3'b110 : take = bltu;
			3'b111 : take = !bltu;
			default: take = 0;
		endcase
	end
endmodule : brunit


