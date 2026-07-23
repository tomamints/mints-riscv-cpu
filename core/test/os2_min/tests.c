#include "kernel.h"

void test_smode_basic(void) {
    printf("entered S-mode\n");
    printf("sstatus=%lx\n", READ_CSR(sstatus));
}

void test_sbi_putchar(void) {
    printf("SBI putchar test\n");
    sbi_putchar('S');
    sbi_putchar('\n');
}

void test_sbi_getchar(void) {
    printf("SBI getchar test\n");
    long ch;
    do {
        ch = sbi_getchar();
    } while (ch < 0);
    printf("sbi input=");
    sbi_putchar((char) ch);
    sbi_putchar('\n');
}

void test_sbi_timer(void) {
    printf("SBI timer test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    WRITE_CSR(sie, READ_CSR(sie) | SIE_STIE);
    WRITE_CSR(sstatus, READ_CSR(sstatus) | SSTATUS_SIE);
    struct sbiret ret = sbi_set_timer(READ_CSR(time) + 10000);
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_set_timer failed error=%ld", ret.error);
    for (;;)
        ;
}

void test_smode_trap(void) {
    printf("entered S-mode trap test\n");
    WRITE_CSR(sepc, 0x80000000UL);
    printf("probe sepc=%lx\n", READ_CSR(sepc));
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    __asm__ __volatile__("ecall");
    printf("returned from S trap\n");
}
