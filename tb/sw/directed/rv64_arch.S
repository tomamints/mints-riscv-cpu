/* Bare-metal architectural regressions. Select one case with -DTEST_<case>. */
.option norvc
.option norelax
.section .text.init,"ax"
.globl _start
_start:
    la t0, trap
    csrw mtvec, t0
    csrw medeleg, zero

#if defined(TEST_mconfigptr)
    csrr t0, 0xf15
    bnez t0, fail
    la s0, readonly_write
    li s1, 2
readonly_write:
    csrw 0xf15, zero
    j fail

#elif defined(TEST_hpm_s) || defined(TEST_hpm_u)
    /* Check that the machine view exists and that HPM3 cannot be enabled. */
    csrr t0, 0xc03
    bnez t0, fail
    csrsi mcounteren, 8
    csrr t0, mcounteren
    bnez t0, fail
    csrsi scounteren, 8
    csrr t0, scounteren
    bnez t0, fail

    /* Permit the lower privilege mode to fetch the test from RAM. */
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 15
    csrw pmpcfg0, t0
    li t0, 0x1800
    csrc mstatus, t0
#ifdef TEST_hpm_s
    li t0, 0x800
    csrs mstatus, t0
#endif
    la s0, hpm_read
    li s1, 2
    csrw mepc, s0
    mret
hpm_read:
    csrr t0, 0xc03
    j fail

#elif defined(TEST_minstret)
    li t0, 123
    csrw minstret, t0
    fence.i
    csrr s0, minstret
    li t0, 124
    bne s0, t0, fail
    fence.i
    csrr t2, minstret
    csrrci t2, minstret, 0
    fence.i
    csrr s1, minstret
    sub t0, s1, s0
    /* Count the first read through the second fence, inclusive. */
    li t1, 7
    bne t0, t1, fail
    j pass

#elif defined(TEST_compressed_mtval)
    la s0, compressed_illegal
    li s1, 2
compressed_illegal:
    .2byte 0x2000 /* C.FLD encoding with D absent. */
    .2byte 0x1235 /* Make a 32-bit fetch distinguishable from the exception value. */
    j fail

#elif defined(TEST_fence_i)
    la t0, patched
    jalr ra, 0(t0)
    bnez a0, fail
    li t1, 0x00100513 /* addi a0, zero, 1 */
    sw t1, 0(t0)
    .word 0xfff7978f /* FENCE.I with nonzero imm, rs1, and rd. */
    jalr ra, 0(t0)
    li t1, 1
    bne a0, t1, fail
    j pass
.balign 4
patched:
    addi a0, zero, 0
    ret

#elif defined(TEST_stvec)
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 15
    csrw pmpcfg0, t0
    csrsi medeleg, 8 /* Delegate breakpoint to S-mode. */
    la t0, fail
    csrw stvec, t0
    li t0, 0x1800
    csrc mstatus, t0
    li t0, 0x800
    csrs mstatus, t0
    la t0, supervisor_entry
    csrw mepc, t0
    mret
supervisor_entry:
    la t0, supervisor_trap
    csrw stvec, t0
breakpoint:
    ebreak
    j fail
.balign 4
supervisor_trap:
    csrr t0, scause
    li t1, 3
    bne t0, t1, fail
    csrr t0, sepc
    la t1, breakpoint
    bne t0, t1, fail
    csrr t0, stval
    bne t0, t1, fail
    j pass
#else
#error Select an architectural regression
#endif

.balign 4
trap:
#if defined(TEST_mconfigptr) || defined(TEST_hpm_s) || defined(TEST_hpm_u) || defined(TEST_compressed_mtval)
    csrr t0, mepc
    bne t0, s0, fail
    csrr t0, mcause
    bne t0, s1, fail
#ifdef TEST_compressed_mtval
    csrr t0, mtval
    li t1, 0x2000
    bne t0, t1, fail
#endif
    j pass
#endif
fail:
    li a0, 3
    j report
pass:
    li a0, 1
report:
    la t0, tohost
    sw a0, 0(t0)
    j report

.section .tohost,"aw"
.balign 8
.globl tohost
tohost: .dword 0
