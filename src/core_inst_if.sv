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
    logic bp_update_valid;
    Addr bp_update_pc;
    logic bp_update_taken;
    Addr bp_update_target;
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
        output  rready,
        output  is_hazard,
        output  next_pc,
        output  bp_update_valid,
        output  bp_update_pc,
        output  bp_update_taken,
        output  bp_update_target
    );

    modport slave(
        output   rvalid, raddr, rdata, is_rvc, expt, predicted_taken, predicted_next_pc,
        input  rready, is_hazard, next_pc, bp_update_valid, bp_update_pc, bp_update_taken, bp_update_target
    );

endinterface
