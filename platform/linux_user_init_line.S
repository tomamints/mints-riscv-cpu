    .section .text.start, "ax", @progbits
    .globl _start
    .type _start, @function
_start:
    li a0, -100
    la a1, console_path
    li a2, 2
    li a3, 0
    li a7, 56
    ecall

    mv s0, a0
    bgez s0, have_console
    li s0, 0

have_console:
    mv a0, s0
    la a1, banner
    la a2, banner_end
    sub a2, a2, a1
    li a7, 64
    ecall

read_line:
    mv a0, s0
    la a1, prompt
    la a2, prompt_end
    sub a2, a2, a1
    li a7, 64
    ecall

    mv a0, s0
    la a1, input_buf
    li a2, 64
    li a7, 63
    ecall

    mv s1, a0
    blez s1, read_line

    mv a0, s0
    la a1, line_prefix
    la a2, line_prefix_end
    sub a2, a2, a1
    li a7, 64
    ecall

    mv a0, s0
    la a1, input_buf
    mv a2, s1
    li a7, 64
    ecall

    j read_line

    .section .rodata, "a", @progbits
console_path:
    .asciz "/dev/console"
banner:
    .ascii "TTY line test\n"
banner_end:
prompt:
    .ascii "type line then Enter> "
prompt_end:
line_prefix:
    .ascii "read line: "
line_prefix_end:

    .section .bss, "aw", @nobits
    .balign 8
input_buf:
    .skip 64
