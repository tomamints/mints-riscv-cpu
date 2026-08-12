import eei::*;

module branch_predictor #(
    parameter int unsigned PHT_ENTRIES = 128
) (
    input  logic clk,
    input  logic rst,

    input  logic inst_valid,
    input  Addr  pc,
    input  Inst  inst,
    input  logic is_rvc,

    output logic prediction_valid,
    output logic predicted_taken,
    output Addr  predicted_next_pc,

    input  logic update_valid,
    input  Addr  update_pc,
    input  logic update_taken,
    /* verilator lint_off UNUSED */
    input  Addr  update_target
    /* verilator lint_on UNUSED */
);

    localparam int unsigned PHT_INDEX_WIDTH = $clog2(PHT_ENTRIES);

    logic [1:0] pht [PHT_ENTRIES];
    logic       pht_valid [PHT_ENTRIES];
    logic [PHT_INDEX_WIDTH-1:0] predict_index;
    logic [PHT_INDEX_WIDTH-1:0] update_index;
    logic is_branch;

    function automatic Addr branch_imm(input Inst branch_inst);
        logic [11:0] imm_b;
        begin
            imm_b = {branch_inst[31], branch_inst[7], branch_inst[30:25], branch_inst[11:8]};
            return Addr'({{(XLEN - $bits(imm_b) - 1){branch_inst[31]}}, imm_b, 1'b0});
        end
    endfunction

    assign is_branch = inst[6:0] == OP_BRANCH;
    assign predict_index = pc[1 +: PHT_INDEX_WIDTH];
    assign update_index = update_pc[1 +: PHT_INDEX_WIDTH];

    always_comb begin
        prediction_valid = inst_valid && is_branch;
        predicted_taken =
            prediction_valid &&
            (pht_valid[predict_index] ? pht[predict_index][1] : inst[31]);
        predicted_next_pc = predicted_taken
            ? pc + branch_imm(inst)
            : pc + (is_rvc ? Addr'(2) : Addr'(4));
    end

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            for (int i = 0; i < PHT_ENTRIES; i++) begin
                pht[i] <= 2'b01;
                pht_valid[i] <= 1'b0;
            end
        end else if (update_valid) begin
            pht_valid[update_index] <= 1'b1;
            if (update_taken) begin
                if (pht[update_index] != 2'b11) begin
                    pht[update_index] <= pht[update_index] + 2'b01;
                end
            end else begin
                if (pht[update_index] != 2'b00) begin
                    pht[update_index] <= pht[update_index] - 2'b01;
                end
            end
        end
    end

    // Target prediction is still computed from the current instruction immediate.
    // A BTB can later replace this path without changing the frontend/backend contract.

endmodule
