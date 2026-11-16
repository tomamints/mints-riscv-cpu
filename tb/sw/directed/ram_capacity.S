#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV64U
RVTEST_CODE_BEGIN
#ifdef CAPACITY_INVALID
    # First byte outside the board RAM must never alias to its first byte.
    li t0, 0x84000000
    sd zero, 0(t0)
    fence
    RVTEST_FAIL
#else
    li TESTNUM, 1
    li t0, 0x80fffff8
    li t1, 0x123456789abcdef0
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail
    li TESTNUM, 2
    li t0, 0x81000000
    not t1, t1
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail
    # Unaligned access above the historical 16 MiB normal-memory boundary.
    # This crosses an eight-byte word and must be split by memunit.
    li TESTNUM, 3
    sd t1, 5(t0)
    ld t2, 5(t0)
    bne t1, t2, fail
    li TESTNUM, 4
    li t0, 0x83fffff8
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, fail
    li TESTNUM, 5
    li t1, 0xa5
    sb t1, 7(t0)
    lbu t2, 7(t0)
    bne t1, t2, fail
    li TESTNUM, 6
    li t1, 0x7654
    sh t1, 6(t0)
    lhu t2, 6(t0)
    bne t1, t2, fail
    li TESTNUM, 7
    li t1, 0x12345678
    sw t1, 4(t0)
    lwu t2, 4(t0)
    bne t1, t2, fail
    RVTEST_PASS
#endif
fail:
    RVTEST_FAIL
RVTEST_CODE_END
.data
RVTEST_DATA_BEGIN
RVTEST_DATA_END
