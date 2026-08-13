import eei::*;

interface core_data_if;

    // -----------------------
    // 信号定義 (var)
    // -----------------------
    logic                       valid;
    logic                       ready;
    logic [XLEN-1:0]            addr;
    logic                       wen;
    logic [MEMBUS_DATA_WIDTH-1:0]     wdata;
    logic [(MEMBUS_DATA_WIDTH/8)-1:0] wmask;
    logic                       rvalid;
    logic [MEMBUS_DATA_WIDTH-1:0]     rdata;
    logic                       fast_load_req;
    logic [XLEN-1:0]            fast_load_addr;
    logic [2:0]                 fast_load_funct3;
    logic                       fast_load_valid;
    logic [MEMBUS_DATA_WIDTH-1:0]     fast_load_data;

    logic                       is_amo;
    logic                       aq;
    logic                       rl;
    AMOOp                       amoop;
    logic [2:0]                 funct3;




    // -----------------------
    // modport master
    // Veryl:
    //   valid: output,
    //   ready: input, ...
    //   is_Zaamo: import
    // -----------------------
    modport master (
        output valid,
        input  ready,
        output addr,
        output wen,
        output wdata,
        output wmask,
        input  rvalid,
        input  rdata,
        output fast_load_req,
        output fast_load_addr,
        output fast_load_funct3,
        input  fast_load_valid,
        input  fast_load_data,
        output is_amo,
        output aq,
        output rl,
        output amoop,
        output funct3,

        import is_Zaamo
    );


    // -----------------------
    // modport slave
    // Veryl:
    //   is_Zaamo: import,
    //   ..converse(master)
    //
    // converse(master):
    //   master の入出力を反転させた modport
    // -----------------------
    modport slave (
        import is_Zaamo,

        input  valid,
        output ready,
        input  addr,
        input  wen,
        input  wdata,
        input  wmask,
        output rvalid,
        output rdata,
        input  fast_load_req,
        input  fast_load_addr,
        input  fast_load_funct3,
        output fast_load_valid,
        output fast_load_data,
        input  is_amo,
        input  aq,
        input  rl,
        input  amoop,
        input  funct3
    );


    // -----------------------
    // modport all_input
    // Veryl:
    //   ..input
    //
    // → interface 内の全シグナルを input として露出
    // -----------------------
    modport all_input (
        input valid,
        input ready,
        input addr,
        input wen,
        input wdata,
        input wmask,
        input rvalid,
        input rdata,
        input fast_load_req,
        input fast_load_addr,
        input fast_load_funct3,
        input fast_load_valid,
        input fast_load_data,
        input is_amo,
        input aq,
        input rl,
        input amoop,
        input funct3,

        import is_Zaamo
    );

    // -----------------------
    // is_Zaamo() function
    // Veryl:
    //   return is_amo && (amoop != LR && amoop != SC);
    // -----------------------
    function logic is_Zaamo();
        return is_amo && (amoop != LR) && (amoop != SC);
    endfunction


endinterface
