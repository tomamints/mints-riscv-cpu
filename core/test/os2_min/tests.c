#include "kernel.h"

volatile uint64_t pmp_protected_word __attribute__((aligned(8))) = 0x1122334455667788ULL;
volatile int pmp_load_fault_seen = -1;

void test_smode_basic(void) {
    printf("entered S-mode\n");
    printf("sstatus=%lx\n", READ_CSR(sstatus));
}

void test_sbi_putchar(void) {
    printf("SBI putchar test\n");
    sbi_putchar('T');
    sbi_putchar('o');
    sbi_putchar('m');
    sbi_putchar('a');
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
    WRITE_CSR(sie, READ_CSR(sie) | SIE_STIE); // SIE.STIEをセットして、S-modeでのタイマー割り込みを有効化
    WRITE_CSR(sstatus, READ_CSR(sstatus) | SSTATUS_SIE); // SSTATUS.SIEをセットして、S-modeでの割り込みを有効化
    for (int i = 0; i < 3; i++) {
        printf("timer wait %d\n", i);
        struct sbiret ret = sbi_set_timer(READ_CSR(time) + 10000);
        if (ret.error != SBI_SUCCESS)
            PANIC("sbi_set_timer failed error=%ld", ret.error);
        __asm__ __volatile__("wfi"); //wait for interruptで、割り込みが来るまで待機する
        printf("timer woke %d\n", i);
    }
}

void test_smode_trap(void) {
    printf("entered S-mode trap test\n");
    WRITE_CSR(sepc, 0x80000000UL);
    printf("probe sepc=%lx\n", READ_CSR(sepc));
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    __asm__ __volatile__("ecall");
    printf("returned from S trap\n");
}

void test_pmp_data_fault(void) {
    printf("PMP data fault test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    pmp_load_fault_seen = 0;
    __asm__ __volatile__("ld zero, 0(%0)" :: "r" (&pmp_protected_word) : "memory");
    if (!pmp_load_fault_seen)
        PANIC("PMP load fault was not raised");
    printf("PMP load fault OK\n");
}
