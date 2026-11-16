/*
 * C test entry (restored; original was not tracked).
 * Initializes gp and sp, clears .bss, then calls main().
 * Tests report success/failure themselves through the debug MMIO register.
 * If main() returns, the test is reported as failed: the value written is odd
 * and != 1, which the simulator top (src/top.sv debug MMIO) prints as
 * "test failed!" and finishes the simulation.
 */
#ifndef DEBUG_MMIO_ADDR
#define DEBUG_MMIO_ADDR 0x40000000
#endif
#define MAIN_RETURNED_CODE 0x3

    .section .text.init, "ax", @progbits
    .globl _start
_start:
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, __stack_top

    la      t0, __bss_start
    la      t1, __bss_end
1:
    bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    call    main

    /* main returned without a success report */
    li      t0, DEBUG_MMIO_ADDR
    li      t1, MAIN_RETURNED_CODE
    sd      t1, 0(t0)
3:
    j       3b
