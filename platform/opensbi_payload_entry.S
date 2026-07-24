    .section .text.boot
    .globl _start
_start:
    la      sp, __stack_top
    call    payload_main
1:
    wfi
    j       1b
