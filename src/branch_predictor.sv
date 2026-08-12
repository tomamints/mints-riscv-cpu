import eei::*;

module branch_predictor (
    input  logic inst_valid,
    input  Addr  pc,
    input  Inst  inst,
    input  logic is_rvc,

    output logic prediction_valid,
    output logic predicted_taken,
    output Addr  predicted_next_pc,

    /* verilator lint_off UNUSED */
    input  logic update_valid,
    input  Addr  update_pc,
    input  logic update_taken,
    input  Addr  update_target
    /* verilator lint_on UNUSED */
);

    function automatic Addr branch_imm(input Inst branch_inst);
        logic [11:0] imm_b;
        begin
            imm_b = {branch_inst[31], branch_inst[7], branch_inst[30:25], branch_inst[11:8]};
            return Addr'({{(XLEN - $bits(imm_b) - 1){branch_inst[31]}}, imm_b, 1'b0});
        end
    endfunction

    always_comb begin
        prediction_valid = inst_valid && inst[6:0] == OP_BRANCH;
        predicted_taken = prediction_valid && inst[31];
        predicted_next_pc = predicted_taken
            ? pc + branch_imm(inst)
            : pc + (is_rvc ? Addr'(2) : Addr'(4));
    end

    // Static predictor for now. Update inputs are kept for later PHT/BTB/RAS variants.

endmodule
