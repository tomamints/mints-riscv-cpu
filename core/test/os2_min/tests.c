#include "kernel.h"

volatile uint64_t pmp_protected_word __attribute__((aligned(8))) = 0x1122334455667788ULL;
volatile int pmp_load_fault_seen = -1;
volatile int pmp_store_fault_seen = -1;
volatile int pmp_exec_fault_seen = -1;
volatile int umode_step = -1;
volatile int umode_ecall_seen = -1;

#define PMP_PROTECTED_WORD_INITIAL 0x1122334455667788ULL

__attribute__((noinline, aligned(8)))
void pmp_protected_exec_target(void) {
    __asm__ __volatile__("nop" ::: "memory");
}

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

    pmp_store_fault_seen = 0;
    __asm__ __volatile__("sd zero, 0(%0)" :: "r" (&pmp_protected_word) : "memory");
    if (!pmp_store_fault_seen)
        PANIC("PMP store fault was not raised");
    printf("PMP store fault OK\n");

    struct sbiret ret = sbi_test_read_pmp_word();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_read_pmp_word failed error=%ld", ret.error);
    if ((uint64_t) ret.value != PMP_PROTECTED_WORD_INITIAL)
        PANIC("PMP store changed protected word value=%lx", ret.value);
    printf("PMP store side effect blocked\n");

    ret = sbi_test_allow_exec_only_target();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_allow_exec_only_target failed error=%ld", ret.error);
    pmp_protected_exec_target();
    printf("PMP exec-only fetch OK\n");

    ret = sbi_test_protect_exec_target();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_protect_exec_target failed error=%ld", ret.error);
    pmp_exec_fault_seen = 0;
    pmp_protected_exec_target();
    if (!pmp_exec_fault_seen)
        PANIC("PMP exec fault was not raised");
    printf("PMP exec fault OK\n");
}

__attribute__((noreturn, noinline, aligned(4)))
void user_entry(void) {
    register long a0 __asm__("a0") = 0x1234;

    umode_step = 1;
    __asm__ __volatile__("ecall" : "+r"(a0) :: "memory");
    if (a0 == 0x5678)
        umode_step = 2;
    else
        umode_step = -2;

    __asm__ __volatile__("ecall" :: "r"(a0) : "memory");
    for (;;)
        ;
}

void test_umode_transition(void) {
    printf("U-mode transition test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);

    umode_step = 0;
    umode_ecall_seen = 0;

    uintptr_t sstatus = READ_CSR(sstatus);
    sstatus &= ~SSTATUS_SPP;
    sstatus |= SSTATUS_SPIE;
    WRITE_CSR(sstatus, sstatus);
    WRITE_CSR(sepc, (uintptr_t) user_entry);
    __asm__ __volatile__("sret");
    PANIC("returned from U-mode test");
}
