    .section .text.init
    .globl _start
_start:
    li      a0, 0x0
    li      a1, 0x87f00000
    li      t0, 0x80000000
    jr      t0
    nop
