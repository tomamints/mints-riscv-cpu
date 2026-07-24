import eei::*;

module uart_ns16550 (
	input logic clk,
	input logic rst,
	Membus.slave membus
);

	logic [7:0] lcr;
	logic [7:0] ier;
	logic [7:0] dll;
	logic [7:0] dlm;
	logic [7:0] fcr;
	logic [7:0] mcr;
	logic [7:0] scr;

	function automatic logic [7:0] write_byte(
		input logic [MEMBUS_DATA_WIDTH-1:0] wdata,
		input logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask,
		input logic [2:0] addr_low
	);
		logic [2:0] lane;
		lane = addr_low;
		if (wmask[lane]) begin
			write_byte = wdata[lane * 8 +: 8];
		end else begin
			write_byte = wdata[7:0];
		end
	endfunction

	function automatic logic [7:0] read_reg(input Addr addr);
		logic [2:0] reg_addr;
		logic dlab;
		reg_addr = addr[2:0];
		dlab = lcr[7];

		unique case (reg_addr)
			UART_REG_RBR_THR_DLL[2:0]: read_reg = dlab ? dll : 8'h00;
			UART_REG_IER_DLM[2:0]:     read_reg = dlab ? dlm : ier;
			UART_REG_IIR_FCR[2:0]:     read_reg = 8'h01;
			UART_REG_LCR[2:0]:         read_reg = lcr;
			UART_REG_MCR[2:0]:         read_reg = mcr;
			UART_REG_LSR[2:0]:         read_reg = 8'b0110_0000;
			UART_REG_MSR[2:0]:         read_reg = 8'h00;
			UART_REG_SCR[2:0]:         read_reg = scr;
			default:                   read_reg = 8'h00;
		endcase
	endfunction

	function automatic logic [MEMBUS_DATA_WIDTH-1:0] read_lane_data(input Addr addr);
		read_lane_data = '0;
		read_lane_data[addr[2:0] * 8 +: 8] = read_reg(addr);
	endfunction

	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			membus.ready <= 1'b1;
			membus.rvalid <= 1'b0;
			membus.rdata <= '0;
			lcr <= 8'h00;
			ier <= 8'h00;
			dll <= 8'h00;
			dlm <= 8'h00;
			fcr <= 8'h00;
			mcr <= 8'h00;
			scr <= 8'h00;
		end else begin
			membus.ready <= 1'b1;
			membus.rvalid <= membus.valid;
			membus.rdata <= membus.valid ? read_lane_data(membus.addr) : '0;

			if (membus.valid) begin
				logic [7:0] wbyte;
				logic [2:0] reg_addr;
				logic dlab;

				wbyte = write_byte(membus.wdata, membus.wmask, membus.addr[2:0]);
				reg_addr = membus.addr[2:0];
				dlab = lcr[7];

				if (membus.wen) begin
					unique case (reg_addr)
						UART_REG_RBR_THR_DLL[2:0]: begin
							if (dlab) begin
								dll <= wbyte;
							end else begin
								$write("%c", wbyte);
								$fflush();
							end
						end
						UART_REG_IER_DLM[2:0]: begin
							if (dlab) begin
								dlm <= wbyte;
							end else begin
								ier <= wbyte;
							end
						end
						UART_REG_IIR_FCR[2:0]: fcr <= wbyte;
						UART_REG_LCR[2:0]:     lcr <= wbyte;
						UART_REG_MCR[2:0]:     mcr <= wbyte;
						UART_REG_SCR[2:0]:     scr <= wbyte;
						default: ;
					endcase
				end
			end
		end
	end

endmodule : uart_ns16550
