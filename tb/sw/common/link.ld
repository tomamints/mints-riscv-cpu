/*
 * Linker script for C tests (restored; original was not tracked).
 * The RAM image is loaded from offset 0 of the RAM model, i.e. physical
 * MMAP_RAM_BEGIN = 0x80000000 (src/eei.sv). The image is flat (objcopy -O
 * binary), so .bss is not in the file and is cleared by entry.S.
 * Kept inside the first 16 MiB (the current cacheable window).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

STACK_SIZE = 0x10000;

SECTIONS
{
    . = ORIGIN(RAM);

    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(8) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(8) {
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(8) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > RAM

    .stack (NOLOAD) : ALIGN(16) {
        . = . + STACK_SIZE;
        __stack_top = .;
    } > RAM

    /DISCARD/ : {
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
        *(.comment)
    }
}
