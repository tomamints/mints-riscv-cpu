import eei::*;
import corectrl::*;

interface core_inst_if;
    logic rvalid;
    logic rready;
    Addr  raddr;
    Inst  rdata;
    logic is_rvc;
    ExceptionInfo expt;
    logic predicted_taken;
    Addr predicted_next_pc;
    logic predicted_from_btb;
    logic predicted_from_ras;
    logic bp_update_valid;
    logic bp_update_is_branch;
    logic bp_update_is_jalr;
    logic bp_update_is_call;
    logic bp_update_is_return;
    Addr bp_update_pc;
    logic bp_update_taken;
    Addr bp_update_target;
    Addr bp_update_return_addr;
    logic is_hazard;
    Addr next_pc;


    modport master(
        input   rvalid,
        input   raddr,
        input   rdata,
        input   is_rvc,
        input   expt,
        input   predicted_taken,
        input   predicted_next_pc,
        input   predicted_from_btb,
        input   predicted_from_ras,
        output  rready,
        output  is_hazard,
        output  next_pc,
        output  bp_update_valid,
        output  bp_update_is_branch,
        output  bp_update_is_jalr,
        output  bp_update_is_call,
        output  bp_update_is_return,
        output  bp_update_pc,
        output  bp_update_taken,
        output  bp_update_target,
        output  bp_update_return_addr
    );

    modport slave(
        output   rvalid, raddr, rdata, is_rvc, expt, predicted_taken, predicted_next_pc, predicted_from_btb, predicted_from_ras,
        input  rready, is_hazard, next_pc, bp_update_valid, bp_update_is_branch, bp_update_is_jalr, bp_update_is_call, bp_update_is_return, bp_update_pc, bp_update_taken, bp_update_target, bp_update_return_addr
    );

endinterface
