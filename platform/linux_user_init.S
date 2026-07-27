    .section .text.start, "ax", @progbits
    .globl _start
    .type _start, @function
_start:
    li a0, -100
    la a1, console_path
    li a2, 1
    li a3, 0
    li a7, 56
    ecall

    mv s0, a0
    bltz s0, write_stdout

    mv a0, s0
    la a1, console_message
    la a2, console_message_end
    sub a2, a2, a1
    li a7, 64
    ecall

write_stdout:
    li a0, 1
    la a1, message
    la a2, message_end
    sub a2, a2, a1
    li a7, 64
    ecall

    li a0, 0
    li a7, 93
    ecall

2:
    j 2b

    .section .rodata, "a", @progbits
console_path:
    .asciz "/dev/console"
console_message:
    .ascii "Hello from userspace via /dev/console\n"
console_message_end:
message:
    .ascii "Hello from userspace via fd1\n"
message_end:
