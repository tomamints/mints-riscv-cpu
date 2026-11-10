    .section .text.init
    .globl _start
_start:
    li      a0, 0x0
#ifndef LINUX_DTB_ADDR
#define LINUX_DTB_ADDR 0x87f00000          /* legacy simulation profile */
#endif
    li      a1, LINUX_DTB_ADDR
    li      t0, 0x80000000
    jr      t0
    nop
