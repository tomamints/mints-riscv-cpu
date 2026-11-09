/*
 * Minimal boot ROM for C tests and riscv-tests (restored; original was not tracked).
 * Mapped at MMAP_ROM_BEGIN (0x1000, src/eei.sv). Jumps to the RAM base where the
 * test image (RAM hex, 64-bit words from offset 0) is loaded.
 * Built with "-c" and objcopy -O binary, so it must be position independent and
 * contain no relocations.
 */
#ifndef RAM_BASE_ADDR
#define RAM_BASE_ADDR 0x80000000
#endif

    .section .text
    .globl _start
_start:
    li      t0, RAM_BASE_ADDR
    jr      t0
1:
    j       1b
