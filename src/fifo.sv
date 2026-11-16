// Packed payloads cross the port as bits; callers pass DATA_WIDTH=$bits(type).
module fifo #(
	parameter int DATA_WIDTH = 1,
	parameter int WIDTH = 2
	)(
		input logic clk,
		input logic rst,
		input logic flush,
		output logic wready,
		output logic wready_two,
		input logic wvalid,
		input logic [DATA_WIDTH-1:0] wdata,
		input logic rready,
		output logic rvalid,
		output logic [DATA_WIDTH-1:0] rdata
		);

		generate
			if(WIDTH==1)begin:width_one
				always_comb begin
					wready = !rvalid || rready;
					wready_two = 1'b0;
				end

				always_ff @(posedge clk or negedge rst) begin
					if(!rst)begin
						rdata <= '0;
						rvalid <= 1'b0;
					end else begin
						if (flush)begin
							rvalid <=1'b0;
						end else begin
							if(wready&&wvalid)begin
								rdata <= wdata;
								rvalid <= 1;
							end else begin
								if(rready)begin
									rvalid <= 0;
								end
							end
						end
					end
				end
			end else begin: width_multi
				typedef logic [WIDTH-1:0] Ptr;

				Ptr head;
				Ptr tail;
				logic [DATA_WIDTH-1:0] mem[0:(1<<WIDTH)-1];

				logic[WIDTH-1:0] tail_plus1;
				logic[WIDTH-1:0] tail_plus2;

				always_comb begin
					tail_plus1 = tail + 1'b1;
					tail_plus2 = tail + 2'b10;

					wready = (tail_plus1 != head);
					wready_two = wready && (tail_plus2 != head);
					rvalid = (head != tail);
					rdata = mem[head];
				end

				always_ff @(posedge clk or negedge rst) begin
					if(!rst) begin
						head <= '0;
						tail <= '0;
					end else begin
						if(flush)begin
							head <= '0;
							tail <= '0;
						end else begin
							if(wready && wvalid)begin
								mem[tail] <= wdata;
								tail <= tail + 1;
							end
							if (rready && rvalid)begin
								head <= head +1;
							end
						end
`ifdef DEBUG_FIFO
						$display("fifo[%m]: head=%0d tail=%0d wvalid=%b wready=%b rvalid=%b rready=%b",
							head, tail, wvalid, wready, rvalid, rready);
						if (wready && wvalid)
							$display("  write data: %p", wdata);
						if (rready && rvalid)
							$display("  read data : %p", mem[head]);
`endif
					end
				end
			end
		endgenerate
endmodule
