    .section .text.init
    .globl _start
_start:
    li      t0, 0x87f00000
    bne     a1, t0, fail
    bne     a0, zero, fail

    li      t1, 0x40000000
    li      t2, 1
    sd      t2, 0(t1)

1:
    j       1b

fail:
    li      t1, 0x40000000
    li      t2, 2
    sd      t2, 0(t1)
2:
    j       2b
