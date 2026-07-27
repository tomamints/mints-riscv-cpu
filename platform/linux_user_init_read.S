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
    la a1, prompt
    la a2, prompt_end
    sub a2, a2, a1
    li a7, 64
    ecall

read_one:
    mv a0, s0
    la a1, input_byte
    li a2, 1
    li a7, 63
    ecall

    li t0, 1
    bne a0, t0, read_one

    mv a0, s0
    la a1, got_prefix
    la a2, got_prefix_end
    sub a2, a2, a1
    li a7, 64
    ecall

    mv a0, s0
    la a1, input_byte
    li a2, 1
    li a7, 64
    ecall

    mv a0, s0
    la a1, newline
    li a2, 1
    li a7, 64
    ecall

idle:
    j idle

    .section .rodata, "a", @progbits
console_path:
    .asciz "/dev/console"
prompt:
    .ascii "Type one character:\n"
prompt_end:
got_prefix:
    .ascii "read byte: "
got_prefix_end:
newline:
    .ascii "\n"

    .section .bss, "aw", @nobits
    .balign 8
input_byte:
    .skip 1
