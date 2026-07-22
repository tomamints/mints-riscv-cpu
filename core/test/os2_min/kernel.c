#include "kernel.h"

extern char __bss[], __bss_end[], __stack_top[];

_Static_assert(offsetof(struct trap_frame, ra) == 0, "trap_frame ra offset");
_Static_assert(offsetof(struct trap_frame, a0) == 80, "trap_frame a0 offset");
_Static_assert(offsetof(struct trap_frame, s11) == 232, "trap_frame s11 offset");
_Static_assert(offsetof(struct trap_frame, sp) == 240, "trap_frame sp offset");
_Static_assert(sizeof(struct trap_frame) == 248, "trap_frame size");

void supervisor_main(void);

static void enter_supervisor(void (*entry)(void)) {
    uintptr_t mstatus = READ_CSR(mstatus);

    mstatus &= ~(3UL << 11);
    mstatus |=  (1UL << 11); // MPP=S

    WRITE_CSR(mstatus, mstatus);
    WRITE_CSR(mepc, (uintptr_t) entry);
    __asm__ __volatile__("mret");
}

void supervisor_main(void) {
#if defined(OS2_MIN_SBI)
    printf("entered S-mode SBI test\n");
    sbi_putchar('S');
    sbi_putchar('\n');
#elif defined(OS2_MIN_SBI_INPUT)
    printf("entered S-mode SBI input test\n");
    long ch;
    do {
        ch = sbi_getchar();
    } while (ch < 0);
    printf("sbi input=");
    sbi_putchar((char) ch);
    sbi_putchar('\n');
#elif defined(OS2_MIN_SBI_TIMER)
    printf("entered S-mode SBI timer test\n");
    struct sbiret ret = sbi_set_timer(READ_CSR(time) + 10000);
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_set_timer failed error=%ld", ret.error);
    for (;;)
        ;
#elif defined(OS2_MIN_STRAP)
    printf("entered S-mode trap test\n");
    WRITE_CSR(sepc, 0x80000000UL);
    printf("probe sepc=%lx\n", READ_CSR(sepc));
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    __asm__ __volatile__("ecall");
    printf("returned from S trap\n");
#else
    printf("entered S-mode\n");
    printf("sstatus=%lx\n", READ_CSR(sstatus));
#endif
    platform_test_success();
    for (;;);
}

void kernel_main(void) {
    memset(__bss, 0, (size_t) __bss_end - (size_t) __bss);

#ifdef OS2_MIN_ECHO
    printf("OS2 min echo ready\n");
    long ch;
    do {
        ch = getchar();
    } while (ch < 0);

    printf("input=");
    putchar((char) ch);
    putchar('\n');
#elif defined(OS2_MIN_SMODE) || defined(OS2_MIN_STRAP) || defined(OS2_MIN_SBI) || defined(OS2_MIN_SBI_INPUT) || defined(OS2_MIN_SBI_TIMER)
    printf("OS2 min S-mode test\n");
#ifdef OS2_MIN_STRAP
    WRITE_CSR(medeleg, 1UL << MCAUSE_ECALL_FROM_S);
#endif
#ifdef OS2_MIN_SBI_TIMER
    platform_stop_timer();
    WRITE_CSR(mcounteren, READ_CSR(mcounteren) | MCOUNTEREN_TIME);
    WRITE_CSR(mie, READ_CSR(mie) | MIE_MTIE);
#endif
    WRITE_CSR(mtvec, (uintptr_t) kernel_trap_entry);
    enter_supervisor(supervisor_main);
    PANIC("returned from enter_supervisor");
#else
    printf("Hello from MiNTsOS min on my CPU\n");
    printf("0x%x\n", 0x1234abcd);
    printf("kernel base=%lx\n", (uintptr_t) 0x80000000UL);
    printf("%s is coming\n", "Toma");
    printf("%d\n", -11111111);

    if (!strcmp("test2", "test"))
        printf("s1 == s2\n");
    else
        printf("s1 != s2\n");
#endif

    platform_test_success();
    for (;;);
}

__attribute__((section(".text.boot")))
__attribute__((naked))
void boot(void) {
    __asm__ __volatile__(
        "mv sp, %[stack_top]\n"
        "j kernel_main\n"
        :
        : [stack_top] "r" (__stack_top)
    );
}
