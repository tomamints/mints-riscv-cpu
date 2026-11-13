import eei::*;

// DE0-CV board SoC: MiNTs CPU (core_top, SVCPU_RAM_EXTERNAL + SVCPU_PHYSICAL_UART,
// 64 MiB profile) on the on-board SDRAM, loaded over JTAG.
//
// Clocking/reset:
//   CLOCK_50 -> sdram_board_pll (20 MHz clk, shifted DRAM_CLK). The only cold
//   reset is power/PLL lock (power_n). It resets the SDRAM path, the loader and
//   the mailbox. There is no push-button reset: reload = reprogram the FPGA.
//   The CPU (core_top incl. caches, UART, PLIC, ACLINT) is held in reset until
//   the loader's RELEASE response has been consumed (cpu_run). The SDRAM path is
//   never soft-reset while the CPU is held (soft_reset tied low): refresh and
//   the loader keep running.
// Memory ownership: before cpu_run the loader owns the RAM port; the mux
// switches once on cpu_run. RELEASE is only accepted with no loader request
// outstanding (the loader is in REPLY), and the CPU is still in reset in that
// cycle, so no response can cross owners.
// Faults: an adapter fault (range/bridge/protocol) is reported to the loader
// (memory_fault -> error response, sticky fault) and shown on LEDR5. It is
// never discarded silently; after release it stops the RAM port (adapter
// behaviour) and stays visible on the LED.
//
// LEDR: 0 heartbeat, 1 PLL lock, 2 RAM cleared, 3 CPU running, 4 SDRAM init
//       done, 5 memory (adapter) fault, 6 loader fault, 7 UART TX overflow
//       seen, 8 UART RX overrun seen, 9 core led[0].
module de0cv_soc_top #(
    parameter BOOTROM_HEX = "bootrom_linux.hex",   // untyped for Quartus $readmemh
    parameter int unsigned MAILBOX_WORDS = 1024
) (
    input  wire        CLOCK_50,
    output wire [9:0]  LEDR,
    input wire [9:0] SW,
    input wire [3:0] KEY_N,
    input  wire        UART_RXD,
    output wire        UART_TXD,
    output wire [12:0] DRAM_ADDR,
    output wire [1:0]  DRAM_BA,
    output wire        DRAM_CLK, DRAM_CKE, DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N,
    output wire        DRAM_LDQM, DRAM_UDQM,
    inout  wire [15:0] DRAM_DQ
);
    localparam int unsigned CLK_HZ = 20_000_000;

    // ---------------- clock / cold reset ----------------
    wire clk, locked;
    sdram_board_pll #(.CLK_HZ(CLK_HZ)) clocking_block (.clock_50(CLOCK_50), .clk(clk), .dram_clk(DRAM_CLK), .locked(locked));
    logic [7:0] power_pipe = '0;
    always_ff @(posedge clk or negedge locked)
        if (!locked) power_pipe <= '0; else power_pipe <= {power_pipe[6:0], 1'b1};
    wire power_n = power_pipe[7];

    // ---------------- virtual JTAG node ----------------
    wire tck, tdi, tdo, cdr, sdr, udr;
    wire [1:0] vir;
    sld_virtual_jtag #(.sld_auto_instance_index("NO"), .sld_instance_index(0), .sld_ir_width(2)) u_jtag (
        .tck(tck), .tdi(tdi), .tdo(tdo), .ir_in(vir), .ir_out(2'b00),
        .virtual_state_cdr(cdr), .virtual_state_sdr(sdr), .virtual_state_udr(udr),
        .virtual_state_e1dr(), .virtual_state_pdr(), .virtual_state_e2dr(),
        .virtual_state_cir(), .virtual_state_uir(), .tms(), .jtag_state_tlr(),
        .jtag_state_rti(), .jtag_state_sdrs(), .jtag_state_cdr(), .jtag_state_sdr(),
        .jtag_state_e1dr(), .jtag_state_pdr(), .jtag_state_e2dr(), .jtag_state_udr(),
        .jtag_state_sirs(), .jtag_state_cir(), .jtag_state_sir(), .jtag_state_e1ir(),
        .jtag_state_pir(), .jtag_state_e2ir(), .jtag_state_uir()
    );

    de0cv_soc_core #(.BOOTROM_HEX(BOOTROM_HEX), .MAILBOX_WORDS(MAILBOX_WORDS)) soc (
        .clk(clk), .power_n(power_n), .locked(locked),
        .tck(tck), .tdi(tdi), .cdr(cdr), .sdr(sdr), .udr(udr), .vir(vir), .tdo(tdo),
        .LEDR(LEDR), .SW(SW), .KEY_N(KEY_N), .UART_RXD(UART_RXD), .UART_TXD(UART_TXD),
        .DRAM_ADDR(DRAM_ADDR), .DRAM_BA(DRAM_BA), .DRAM_CKE(DRAM_CKE), .DRAM_CS_N(DRAM_CS_N),
        .DRAM_RAS_N(DRAM_RAS_N), .DRAM_CAS_N(DRAM_CAS_N), .DRAM_WE_N(DRAM_WE_N),
        .DRAM_LDQM(DRAM_LDQM), .DRAM_UDQM(DRAM_UDQM), .DRAM_DQ(DRAM_DQ)
    );
endmodule
