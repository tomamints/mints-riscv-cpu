import eei::*;

module instruction_translation (
	input logic clk,
	input logic rst,
	input logic flush,

	input logic req_valid,
	output logic req_ready,
	input Addr req_va,
	input PrivMode req_priv_mode,
	input UIntX satp,

	output logic rsp_valid,
	input logic rsp_ready,
	output Addr rsp_pa,
	output logic rsp_fault,
	output Sv39Fault rsp_fault_detail,
	output CsrCause rsp_fault_cause,
	output Addr rsp_fault_value,

	output logic ptw_mem_valid,
	output Addr ptw_mem_addr,
	input logic ptw_mem_ready,
	input logic ptw_mem_rvalid,
	input logic ptw_mem_error,
	input logic [MEMBUS_DATA_WIDTH-1:0] ptw_mem_rdata
);

	address_translation translation (
		.clk(clk),
		.rst(rst),
		.flush(flush),
		.req_valid(req_valid),
		.req_ready(req_ready),
		.req_va(req_va),
		.req_priv_mode(req_priv_mode),
		.req_access_type(PMP_ACCESS_EXEC),
		.req_sum(1'b0),
		.req_mxr(1'b0),
		.satp(satp),
		.rsp_valid(rsp_valid),
		.rsp_ready(rsp_ready),
		.rsp_pa(rsp_pa),
		.rsp_fault(rsp_fault),
		.rsp_fault_detail(rsp_fault_detail),
		.rsp_fault_cause(rsp_fault_cause),
		.rsp_fault_value(rsp_fault_value),
		.ptw_mem_valid(ptw_mem_valid),
		.ptw_mem_addr(ptw_mem_addr),
		.ptw_mem_ready(ptw_mem_ready),
		.ptw_mem_rvalid(ptw_mem_rvalid),
		.ptw_mem_error(ptw_mem_error),
		.ptw_mem_rdata(ptw_mem_rdata)
	);
endmodule : instruction_translation
