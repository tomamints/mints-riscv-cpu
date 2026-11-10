# Directed fence.i / posted-store counterexample (C3 M2), riscv-tests env/p.
# Each slot k (0..15):
#   - [HIT variant] load patch_k first so the D-cache holds the line;
#   - write slot marker k+1 to markers[k] (identity for the RAM trace);
#   - k nops of phase padding (all BEFORE the final store);
#   - final `sw` of `addi a0,x0,1` over patch_k, immediately followed by fence.i
#     (no loads or other memory operations in between);
#   - patch_k originally holds `addi a0,x0,0`; the test requires a0 == 1.
# TESTNUM = k + 1, so a failure in slot k reports tohost = ((k+1) << 1) | 1.
# Built with -mno-relax / .option norelax so `. - _start` is an assembly-time
# constant. Each slot starts 32-byte aligned (nop fill); the k-nop padding moves patch_k through all
# eight word offsets of an I-cache line (and both halves of a 64-bit word).
#include "riscv_test.h"
#include "test_macros.h"

#define INSN_LI_A0_1 0x00100513
#define INSN_LI_A0_0 0x00000513

.macro SLOT k
    # Align the slot start to 32 bytes with real nops. (.balign pads code with
    # zero bytes when relaxation is off, and 0x0000 is an illegal instruction.)
    .fill ((32 - ((. - _start) & 31)) & 31) / 4, 4, 0x00000013
    li TESTNUM, \k + 1
    la t0, patch_\k
    li t1, INSN_LI_A0_1
#ifdef FENCE_I_HIT
    lw t5, 0(t0)                 # prefill: D-cache line of patch_k (before the store)
#endif
    la t3, markers
    li t4, \k + 1
    sd t4, \k*8(t3)              # slot marker (traced)
    .rept \k
    nop
    .endr
    sw t1, 0(t0)                 # final store into code
    fence.i
patch_\k:
    .word INSN_LI_A0_0
    li t2, 1
    bne a0, t2, fail
.endm

RVTEST_RV64U
RVTEST_CODE_BEGIN
    .option push
    .option norvc
    .option norelax              # keep the phase-padding layout exact (no linker relaxation)
slots_begin:
    li a0, 0
    SLOT 0
    SLOT 1
    SLOT 2
    SLOT 3
    SLOT 4
    SLOT 5
    SLOT 6
    SLOT 7
    SLOT 8
    SLOT 9
    SLOT 10
    SLOT 11
    SLOT 12
    SLOT 13
    SLOT 14
    SLOT 15
    .option pop
    TEST_PASSFAIL
RVTEST_CODE_END

    .data
RVTEST_DATA_BEGIN
    TEST_DATA
    .balign 64
markers:
    .dword 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
RVTEST_DATA_END
