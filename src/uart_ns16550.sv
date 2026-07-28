import eei::*;
import util::*;

module uart_ns16550 (
	input logic clk,
	input logic rst,
	Membus.slave membus,
	output logic irq
);

	logic [7:0] lcr;
	logic [7:0] ier;
	logic [7:0] dll;
	logic [7:0] dlm;
	logic [7:0] fcr;
	logic [7:0] mcr;
	logic [7:0] scr;
	logic [7:0] rx_data;
	logic rx_valid;
	logic tx_irq_pending;

	assign irq = (rx_valid && ier[0]) || (tx_irq_pending && ier[1]);

	function automatic logic [7:0] get_write_byte(
		input logic [MEMBUS_DATA_WIDTH-1:0] wdata,
		input logic [2:0] addr_low
	);
		get_write_byte = wdata[addr_low * 8 +: 8];
	endfunction

	function automatic logic [7:0] read_reg(input Addr addr);
		logic [2:0] reg_addr;
		logic dlab;
		reg_addr = addr[2:0];
		dlab = lcr[7];

		unique case (reg_addr)
			UART_REG_RBR_THR_DLL[2:0]: read_reg = dlab ? dll : rx_data;
			UART_REG_IER_DLM[2:0]:     read_reg = dlab ? dlm : ier;
			UART_REG_IIR_FCR[2:0]:     read_reg = (rx_valid && ier[0]) ? 8'h04 :
			                                       (tx_irq_pending && ier[1]) ? 8'h02 : 8'h01;
			UART_REG_LCR[2:0]:         read_reg = lcr;
			UART_REG_MCR[2:0]:         read_reg = mcr;
			UART_REG_LSR[2:0]:         read_reg = 8'h60 | {7'b0, rx_valid};
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
			rx_data <= 8'h00;
			rx_valid <= 1'b0;
			tx_irq_pending <= 1'b0;
		end else begin
			logic rbr_read;

			rbr_read =
				membus.valid &&
				!membus.wen &&
				!lcr[7] &&
				(membus.addr[2:0] == UART_REG_RBR_THR_DLL[2:0]);

			membus.ready <= 1'b1;
			membus.rvalid <= membus.valid;
			membus.rdata <= membus.valid ? read_lane_data(membus.addr) : '0;

`ifdef ENABLE_DEBUG_INPUT
			if (!rx_valid && !rbr_read) begin
				longint input_value;
				input_value = util::get_input();
				if (input_value[63:44] == 20'h01010) begin
					if ($test$plusargs("TRACE_UART")) begin
						$display("[UART RX] char=%02x", input_value[7:0]);
					end
					rx_data <= input_value[7:0];
					rx_valid <= 1'b1;
				end
			end
`endif

			if (membus.valid) begin
				logic [7:0] wbyte;
				logic [2:0] reg_addr;
				logic dlab;
				logic byte_write_valid;

				wbyte = get_write_byte(membus.wdata, membus.addr[2:0]);
				reg_addr = membus.addr[2:0];
				dlab = lcr[7];
				byte_write_valid = membus.wmask[membus.addr[2:0]];

				if (membus.wen) begin
					if (byte_write_valid) begin
						unique case (reg_addr)
							UART_REG_RBR_THR_DLL[2:0]: begin
								if (dlab) begin
									dll <= wbyte;
								end else begin
									$write("%c", wbyte);
									$fflush();
									tx_irq_pending <= ier[1];
								end
							end
							UART_REG_IER_DLM[2:0]: begin
								if (dlab) begin
									dlm <= wbyte;
								end else begin
									ier <= wbyte;
									if (!ier[1] && wbyte[1]) begin
										tx_irq_pending <= 1'b1;
									end
								end
							end
							UART_REG_IIR_FCR[2:0]: begin
								fcr <= wbyte;
								if (wbyte[1]) begin
									rx_valid <= 1'b0;
								end
							end
							UART_REG_LCR[2:0]:     lcr <= wbyte;
							UART_REG_MCR[2:0]:     mcr <= wbyte;
							UART_REG_SCR[2:0]:     scr <= wbyte;
							default: ;
						endcase
					end
				end else begin
					if (!dlab && reg_addr == UART_REG_RBR_THR_DLL[2:0]) begin
						rx_valid <= 1'b0;
					end else if (reg_addr == UART_REG_IIR_FCR[2:0]) begin
						if (!(rx_valid && ier[0]) && tx_irq_pending && ier[1]) begin
							tx_irq_pending <= 1'b0;
						end
					end
				end

				if ($test$plusargs("TRACE_UART")) begin
					if (membus.wen && byte_write_valid) begin
						if (!dlab && reg_addr == UART_REG_RBR_THR_DLL[2:0]) begin
							if (ier[1] || tx_irq_pending || rx_valid) begin
								$display("[UART THR] char=%02x ier=%02x txp=%0b rx=%0b irq=%0b",
									wbyte,
									ier,
									tx_irq_pending,
									rx_valid,
									irq);
							end
						end else if (!dlab && reg_addr == UART_REG_IER_DLM[2:0]) begin
							$display("[UART IER] old=%02x new=%02x txp=%0b rx=%0b irq=%0b",
								ier,
								wbyte,
								tx_irq_pending,
								rx_valid,
								irq);
						end
					end else if (!membus.wen && reg_addr == UART_REG_IIR_FCR[2:0]) begin
						$display("[UART IIR] value=%02x ier=%02x txp=%0b rx=%0b irq=%0b",
							read_reg(membus.addr),
							ier,
							tx_irq_pending,
							rx_valid,
							irq);
					end else if (!membus.wen && !dlab && reg_addr == UART_REG_RBR_THR_DLL[2:0]) begin
						$display("[UART RBR] char=%02x ier=%02x txp=%0b rx=%0b irq=%0b",
							rx_data,
							ier,
							tx_irq_pending,
							rx_valid,
							irq);
					end
				end
			end
		end
	end

endmodule : uart_ns16550
