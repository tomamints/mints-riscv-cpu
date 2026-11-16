#include "riscv_test.h"
#include "test_macros.h"
RVTEST_RV64U
RVTEST_CODE_BEGIN
    li TESTNUM, 1
    li t0, 0x10000000
    li t1, 0x80
    sb t1, 3(t0)
    li t1, 2
    sb t1, 0(t0)
    sb zero, 1(t0)
    li t1, 3
    sb t1, 3(t0)
    li t1, 7
    sb t1, 2(t0)
    la t3, message
next_byte:
    lbu t4, 0(t3)
    beqz t4, finish_tx
wait_ready:
    lbu t2, 5(t0)
    andi t2, t2, 0x20
    beqz t2, wait_ready
    sb t4, 0(t0)
    addi t3, t3, 1
    j next_byte
finish_tx:
    lbu t2, 5(t0)
    andi t2, t2, 0x40
    beqz t2, finish_tx
    RVTEST_PASS
fail:
    RVTEST_FAIL
RVTEST_CODE_END
.data
message: .asciz "MiNTs\n"
RVTEST_DATA_BEGIN
RVTEST_DATA_END
