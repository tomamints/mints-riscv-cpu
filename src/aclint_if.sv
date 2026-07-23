import eei::*;

interface aclint_if;

    logic msip;
    logic mtip;
    UInt64 mtime;
    logic setssip;
    logic setstip;

    modport master(
        output msip,
        output mtip,
        output mtime,
        output setssip,
        output setstip
    );

    modport slave(
        input msip,
        input mtip,
        input mtime,
        input setssip,
        input setstip
    );
endinterface
