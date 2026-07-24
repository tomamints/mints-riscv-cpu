import eei::*;
import corectrl::*;

interface core_inst_if;
    logic rvalid;
    logic rready;
    Addr  raddr;
    Inst  rdata;
    logic is_rvc;
    ExceptionInfo expt;
    logic is_hazard;
    Addr next_pc;


    modport master(
        input   rvalid,
        input   raddr,
        input   rdata,
        input   is_rvc,
        input   expt,
        output  rready,
        output  is_hazard,
        output  next_pc
    );

    modport slave(
        output   rvalid, raddr, rdata, is_rvc, expt,
        input  rready, is_hazard, next_pc
    );

endinterface
