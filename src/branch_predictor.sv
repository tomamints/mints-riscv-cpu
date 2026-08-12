import eei::*;

module branch_predictor #(
    parameter int unsigned PHT_ENTRIES = 128,
    parameter int unsigned BTB_ENTRIES = 32,
    parameter int unsigned RAS_ENTRIES = 8
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
    output logic predicted_from_btb,
    output logic predicted_from_ras,

    input  logic update_valid,
    input  logic update_is_branch,
    input  logic update_is_jalr,
    input  logic update_is_call,
    input  logic update_is_return,
    input  Addr  update_pc,
    input  logic update_taken,
    input  Addr  update_target,
    input  Addr  update_return_addr
);

    localparam int unsigned PHT_INDEX_WIDTH = $clog2(PHT_ENTRIES);
    localparam int unsigned BTB_INDEX_WIDTH = $clog2(BTB_ENTRIES);
    localparam int unsigned BTB_TAG_WIDTH = XLEN - 1 - BTB_INDEX_WIDTH;
    localparam int unsigned RAS_INDEX_WIDTH = $clog2(RAS_ENTRIES);

    logic [1:0] pht [PHT_ENTRIES];
    logic       pht_valid [PHT_ENTRIES];
    logic       btb_valid [BTB_ENTRIES];
    logic [BTB_TAG_WIDTH-1:0] btb_tag [BTB_ENTRIES];
    Addr        btb_target [BTB_ENTRIES];
    Addr        ras_stack [RAS_ENTRIES];
    logic [RAS_INDEX_WIDTH-1:0] ras_sp;
    logic       ras_valid;
    logic [PHT_INDEX_WIDTH-1:0] predict_index;
    logic [PHT_INDEX_WIDTH-1:0] update_index;
    logic [BTB_INDEX_WIDTH-1:0] btb_predict_index;
    logic [BTB_INDEX_WIDTH-1:0] btb_update_index;
    logic [BTB_TAG_WIDTH-1:0] btb_predict_tag;
    logic [BTB_TAG_WIDTH-1:0] btb_update_tag;
    logic is_branch;
    logic is_jalr;
    logic is_jalr_return;
    logic btb_hit;
    Addr ras_top;

    function automatic Addr branch_imm(input Inst branch_inst);
        logic [11:0] imm_b;
        begin
            imm_b = {branch_inst[31], branch_inst[7], branch_inst[30:25], branch_inst[11:8]};
            return Addr'({{(XLEN - $bits(imm_b) - 1){branch_inst[31]}}, imm_b, 1'b0});
        end
    endfunction

    function automatic logic is_link_reg(input logic [4:0] reg_addr);
        return reg_addr == 5'd1 || reg_addr == 5'd5;
    endfunction

    assign is_branch = inst[6:0] == OP_BRANCH;
    assign is_jalr = inst[6:0] == OP_JALR;
    assign is_jalr_return =
        is_jalr &&
        inst[11:7] == 5'd0 &&
        is_link_reg(inst[19:15]);
    assign predict_index = pc[1 +: PHT_INDEX_WIDTH];
    assign update_index = update_pc[1 +: PHT_INDEX_WIDTH];
    assign btb_predict_index = pc[1 +: BTB_INDEX_WIDTH];
    assign btb_update_index = update_pc[1 +: BTB_INDEX_WIDTH];
    assign btb_predict_tag = pc[1 + BTB_INDEX_WIDTH +: BTB_TAG_WIDTH];
    assign btb_update_tag = update_pc[1 + BTB_INDEX_WIDTH +: BTB_TAG_WIDTH];
    assign btb_hit =
        btb_valid[btb_predict_index] &&
        btb_tag[btb_predict_index] == btb_predict_tag;
    assign ras_top = ras_stack[ras_sp - RAS_INDEX_WIDTH'(1)];

    always_comb begin
        prediction_valid = inst_valid && (is_branch || (is_jalr && ((is_jalr_return && ras_valid) || btb_hit)));
        predicted_taken = 1'b0;
        predicted_next_pc = pc + (is_rvc ? Addr'(2) : Addr'(4));
        predicted_from_btb = 1'b0;
        predicted_from_ras = 1'b0;

        if (inst_valid && is_branch) begin
            predicted_taken = pht_valid[predict_index] ? pht[predict_index][1] : inst[31];
            predicted_next_pc = predicted_taken
                ? pc + branch_imm(inst)
                : pc + (is_rvc ? Addr'(2) : Addr'(4));
        end else if (inst_valid && is_jalr_return && ras_valid) begin
            predicted_taken = 1'b1;
            predicted_next_pc = ras_top;
            predicted_from_ras = 1'b1;
        end else if (inst_valid && is_jalr && btb_hit) begin
            predicted_taken = 1'b1;
            predicted_next_pc = btb_target[btb_predict_index];
            predicted_from_btb = 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            for (int i = 0; i < PHT_ENTRIES; i++) begin
                pht[i] <= 2'b01;
                pht_valid[i] <= 1'b0;
            end
            for (int i = 0; i < BTB_ENTRIES; i++) begin
                btb_valid[i] <= 1'b0;
                btb_tag[i] <= '0;
                btb_target[i] <= '0;
            end
            for (int i = 0; i < RAS_ENTRIES; i++) begin
                ras_stack[i] <= '0;
            end
            ras_sp <= '0;
            ras_valid <= 1'b0;
        end else begin
            if (update_valid && update_is_branch) begin
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
            if (update_valid && update_is_jalr) begin
                btb_valid[btb_update_index] <= 1'b1;
                btb_tag[btb_update_index] <= btb_update_tag;
                btb_target[btb_update_index] <= update_target;
            end
            if (update_valid && update_is_return && ras_valid) begin
                ras_sp <= ras_sp - RAS_INDEX_WIDTH'(1);
                ras_valid <= ras_sp != RAS_INDEX_WIDTH'(1);
            end
            if (update_valid && update_is_call) begin
                ras_stack[ras_sp] <= update_return_addr;
                ras_sp <= ras_sp + RAS_INDEX_WIDTH'(1);
                ras_valid <= 1'b1;
            end
        end
    end

    // B-type targets still come from the current instruction immediate.
    // Return prediction uses the RAS first, then falls back to the JALR BTB.

endmodule
