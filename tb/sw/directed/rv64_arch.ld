OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
    . = 0x80000000;
    .text : { *(.text.init) }
    . = ALIGN(0x1000);
    .tohost : { *(.tohost) }
}
