`timescale 1ns/1ps
module tb_pmp_prefix;
    import eei::*;
    PrivMode mode;
    PmpAccessType kind;
    logic[63:0] start,size,cfg,pa[8];
    logic actual,expected;
    pmp_checker dut(.priv_mode(mode),.access_start(start),.access_size(size),.access_type(kind),
        .pmpcfg0(cfg),.pmpaddr0(pa[0]),.pmpaddr1(pa[1]),.pmpaddr2(pa[2]),.pmpaddr3(pa[3]),
        .pmpaddr4(pa[4]),.pmpaddr5(pa[5]),.pmpaddr6(pa[6]),.pmpaddr7(pa[7]),.allow(actual));
    pmp_checker_reference reference(.priv_mode(mode),.access_start(start),.access_size(size),.access_type(kind),
        .pmpcfg0(cfg),.pmpaddr0(pa[0]),.pmpaddr1(pa[1]),.pmpaddr2(pa[2]),.pmpaddr3(pa[3]),
        .pmpaddr4(pa[4]),.pmpaddr5(pa[5]),.pmpaddr6(pa[6]),.pmpaddr7(pa[7]),.allow(expected));
    logic[63:0] rng=64'h20261110c0ffee01;
    function automatic logic[63:0] random64();
        rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;
    endfunction
    int checks=0;
    task automatic check();
        #1;
        if(actual!==expected)$fatal(1,"PMP mismatch start=%h size=%h cfg=%h mode=%0d kind=%0d",start,size,cfg,mode,kind);
        checks++;
    endtask
    initial begin
        mode=S;kind=PMP_ACCESS_READ;cfg=0;start=0;size=0;
        for(int j=0;j<8;j++)pa[j]=0;
        // Every trailing-one length at every priority slot, with accesses at
        // both region boundaries, zero size, wrapping addresses and huge sizes.
        for(int j=0;j<8;j++)for(int k=0;k<=64;k++)begin
            logic[63:0] mask,base,last;
            for(int z=0;z<8;z++)pa[z]=0;
            cfg=64'h1f<<(j*8);
            pa[j]=(random64() << (k+1)) | ((64'h1<<k)-1);
            if(k==64)pa[j]='1;
            mask=k>=61 ? '1 : (64'h1<<(k+3))-1;
            base=(pa[j]<<2)&~mask;last=base|mask;
            for(int b=0;b<6;b++)begin
                case(b)
                    0:start=base-1;1:start=base;2:start=base+1;
                    3:start=last-1;4:start=last;5:start=last+1;
                endcase
                for(int s=0;s<8;s++)begin
                    case(s)
                        0:size=0;1:size=1;2:size=2;3:size=4;4:size=8;
                        5:size=64'h8000000000000000;6:size='1;7:size=random64();
                    endcase
                    check();
                end
            end
        end
        // Mixed TOR/NAPOT/OFF regions, permissions, priority and privilege.
        for(int n=0;n<100000;n++)begin
            mode=PrivMode'(random64()%4);kind=PmpAccessType'(random64()%4);
            cfg=random64();start=random64();size=random64();
            for(int j=0;j<8;j++)pa[j]=random64();
            check();
        end
        $display("PMP_PREFIX_PASS checks=%0d",checks);$finish;
    end
endmodule
