# Standalone M->S/Sv39 diagnostic; no OpenSBI or Linux required.
.section .text.boot
.globl _start
_start:
    mv s5, a1
    li t0, 0x10000000
    li t1, 0x83
    sb t1, 3(t0)
    li t1, 2
    sb t1, 0(t0)
    sb zero, 1(t0)
    li t1, 3
    sb t1, 3(t0)
    li t1, 7
    sb t1, 2(t0)
    la t0, mtrap
    csrw mtvec, t0
    li t0, -1
    csrw pmpaddr0, t0
    li t0, 0x1f
    csrw pmpcfg0, t0
    li t0, 7
    csrw mcounteren, t0
    li t0, 0xb109
    csrw medeleg, t0
    csrw satp, zero
    la t0, supervisor_entry
    csrw mepc, t0
    csrr t0, mstatus
    li t1, -6145
    and t0, t0, t1
    li t1, 0x800
    or t0, t0, t1
    csrw mstatus, t0
    mret
supervisor_entry:
    csrw sie, zero
    la t0, trap
    csrw stvec, t0
    mv s5, a1
    la a0, entry_msg
    call puts
    lw t0, 0(s5)
    li t1, 0xffffffffedfe0dd0
    bne t0, t1, bad
    la a0, dtb_msg
    call puts
    .option push
    .option rvc
    c.nop
    .option pop
    la t0, scratch
    li t1, 0x1122334455667788
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, bad
    li t1, 1
    amoadd.d t2, t1, (t0)
    ld t3, 0(t0)
    addi t2, t2, 1
    bne t2, t3, bad
    rdtime t0
    la a0, bare_msg
    call puts
    la t0, root
    li t1, 0xcf
    sd t1, 0(t0)
    li t1, 0x200000cf
    sd t1, 16(t0)
    li t2, 4080
    add t2, t0, t2
    sd t1, 0(t2)
    # A three-level, 4 KiB alias at 0xffffffc000000000 -> scratch.
    la t1, l1
    srli t1, t1, 12
    slli t1, t1, 10
    ori t1, t1, 1
    li t2, 2048
    add t2, t0, t2
    sd t1, 0(t2)
    la t1, l0
    srli t1, t1, 12
    slli t1, t1, 10
    ori t1, t1, 1
    la t2, l1
    sd t1, 0(t2)
    la t1, scratch
    srli t1, t1, 12
    slli t1, t1, 10
    ori t1, t1, 0xcf
    la t2, l0
    sd t1, 0(t2)
    srli t0, t0, 12
    li t1, 0x8000000000000000
    or t0, t0, t1
    sfence.vma
    mv s4, t0
    csrw satp, t0
    csrr t2, satp
    bne t2, s4, satp_bad
    sfence.vma
    la a0, mmu_msg
    call puts
    la t0, high_entry
    li t1, 0xffffffff00000000
    or t0, t0, t1
    jr t0
high_entry:
    la a0, high_msg
    call puts
    la t0, scratch
    ld t1, 0(t0)
    li t2, 0x1122334455667789
    bne t1, t2, bad
    li t0, 0xffffffc000000000
    ld t1, 0(t0)
    bne t1, t2, bad
    li t1, 0x55aa
    sd t1, 0(t0)
    ld t2, 0(t0)
    bne t1, t2, bad
    la a0, page_msg
    call puts
    la a0, pass_msg
    call puts
park:
    j park
satp_bad:
    mv a0, t2
    call hex
    la a0, satp_msg
    call puts
    j park
bad:
    la a0, fail_msg
    call puts
    j park
.balign 4
trap:
    csrr s0, scause
    csrr s1, sepc
    csrr s2, stval
trap_print:
    la a0, trap_msg
    call puts
    mv a0, s0
    call hex
    mv a0, s1
    call hex
    mv a0, s2
    call hex
    j park
.balign 4
mtrap:
    csrr s0, mcause
    csrr s1, mepc
    csrr s2, mtval
    j trap_print
puts:
    li t0, 0x10000000
    mv t3, a0
1:  lbu t1, 0(t3)
    beqz t1, 3f
2:  lbu t2, 5(t0)
    andi t2, t2, 0x20
    beqz t2, 2b
    sb t1, 0(t0)
    addi t3, t3, 1
    j 1b
3:  ret
hex:
    li t0, 0x10000000
    li t3, 16
    mv t4, a0
1:  srli t1, t4, 60
    li t2, 10
    bltu t1, t2, 2f
    addi t1, t1, 39
2:  addi t1, t1, 48
3:  lbu t2, 5(t0)
    andi t2, t2, 0x20
    beqz t2, 3b
    sb t1, 0(t0)
    slli t4, t4, 4
    addi t3, t3, -1
    bnez t3, 1b
4:  lbu t2, 5(t0)
    andi t2, t2, 0x20
    beqz t2, 4b
    li t1, 10
    sb t1, 0(t0)
    ret
.section .rodata
entry_msg: .asciz "\r\nSMODE ENTRY\r\n"
dtb_msg: .asciz "DTB PASS\r\n"
bare_msg: .asciz "S RAM/AMO/TIME PASS\r\n"
mmu_msg: .asciz "SV39 IDENTITY PASS\r\n"
high_msg: .asciz "SV39 HIGH EXEC\r\n"
pass_msg: .asciz "SMODE PROBE PASS\r\n"
fail_msg: .asciz "SMODE PROBE FAIL\r\n"
page_msg: .asciz "SV39 4K LOAD/STORE PASS\r\n"
satp_msg: .asciz "SATP MODE FAIL\r\n"
trap_msg: .asciz "SMODE TRAP scause/sepc/stval:\r\n"
.section .bss
.balign 4096
root: .zero 4096
l1: .zero 4096
l0: .zero 4096
scratch: .zero 4096
