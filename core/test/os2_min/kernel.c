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
#if defined(OS2_MIN_INPUT)
    test_sbi_getchar();
#elif defined(OS2_MIN_STRAP)
    test_smode_trap();
    platform_test_success();
    for (;;)
        ;
#else
    test_smode_basic();
    test_sbi_putchar();
    test_sbi_timer();
#endif
    platform_test_success();
    for (;;);
}

void kernel_main(void) {
    memset(__bss, 0, (size_t) __bss_end - (size_t) __bss);

#if defined(OS2_MIN_INPUT) || defined(OS2_MIN_STRAP) || defined(OS2_MIN_NO_INPUT)
    printf("OS2 min S-mode test\n");
#ifdef OS2_MIN_STRAP
    WRITE_CSR(medeleg, 1UL << MCAUSE_ECALL_FROM_S);
#endif
#ifdef OS2_MIN_NO_INPUT
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
