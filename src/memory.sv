import util::*;

module memory#(
	parameter int DATA_WIDTH = 32,
	parameter int ADDR_WIDTH = 10,
	parameter bit FILEPATH_IS_ENV = 0,
`ifdef SYNTHESIS
	// Quartus 20.1 rejects a string-typed parameter in $readmemh
	parameter FILEPATH = ""
`else
	parameter string FILEPATH = ""
`endif
)(
	input  logic clk,
	input  logic rst,
	membus_if.slave membus
);

	typedef logic [DATA_WIDTH-1:0]         DataType;
	typedef logic [(DATA_WIDTH/8)-1:0]     MaskType;

	DataType mem [0:(1<<ADDR_WIDTH)-1];

	typedef enum logic [0:0] {
		Ready,
		WriteValid
	} state_t;

	state_t             state;
	logic [ADDR_WIDTH-1:0] addr_saved;
	DataType            wdata_saved;
	MaskType            wmask_saved;
	DataType            rdata_saved;

	// メモリ初期化
`ifdef SYNTHESIS
	// Synthesis: the image is the FILEPATH parameter (no host environment).
	// Quartus 20.1 cannot compare a string parameter, so every synthesized
	// instance must name an image (the board ROM; the board RAM is external).
	initial begin
		$readmemh(FILEPATH, mem);
	end
`else
	initial begin
		string init_filepath;
		if (FILEPATH_IS_ENV) begin
			init_filepath = util::get_env(FILEPATH);
		end else begin
			init_filepath = FILEPATH;
		end

		if (init_filepath != "") begin
			$display("memory: initializing from %0s", init_filepath);
			$readmemh(init_filepath, mem);
		end else begin
			$display("memory: no initialization file specified");
		end
	end
`endif

	// Ready は状態に依存
	always_comb begin
		membus.ready = (state == Ready);
	end

	// 書き込み反映
	always_ff @(posedge clk) begin
		if (state == WriteValid) begin
			logic [DATA_WIDTH-1:0] wmask_expanded;
			wmask_expanded = membus.wmask_expand(wmask_saved);
			mem[addr_saved] <= (wdata_saved & wmask_expanded) | (rdata_saved & ~wmask_expanded);
		end
	end

	// 応答・状態制御
	always_ff @(posedge clk or negedge rst) begin
		if (!rst) begin
			state        <= Ready;
			membus.rvalid <= 1'b0;
			membus.rdata  <= '0;
			addr_saved    <= '0;
			wdata_saved   <= '0;
			wmask_saved   <= '0;
			rdata_saved   <= '0;
		end else begin
			case (state)
				Ready: begin
					membus.rvalid <= membus.valid && !membus.wen;
					membus.rdata  <= mem[membus.addr[ADDR_WIDTH-1:0]];

					addr_saved  <= membus.addr[ADDR_WIDTH-1:0];
					wdata_saved <= membus.wdata;
					wmask_saved <= membus.wmask;
					rdata_saved <= mem[membus.addr[ADDR_WIDTH-1:0]];

					if (membus.valid && membus.wen) begin
						state <= WriteValid;
					end
				end
				WriteValid: begin
					state        <= Ready;
					membus.rvalid <= 1'b1;
					membus.rdata  <= rdata_saved;
				end
				default: begin
					state        <= Ready;
					membus.rvalid <= 1'b0;
					membus.rdata  <= '0;
				end
			endcase
		end
	end
endmodule
