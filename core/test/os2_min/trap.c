#include "kernel.h"

void kernel_trap_handler(struct trap_frame *f) {
    uintptr_t mcause = READ_CSR(mcause);
    uintptr_t mepc = READ_CSR(mepc);

    if (mcause == MCAUSE_MACHINE_TIMER_INTERRUPT) {
        platform_stop_timer();
        printf("M timer interrupt\n");
        platform_set_stip();
        return;
    }

    if (mcause == MCAUSE_ECALL_FROM_S) {
        if (!(f->a7 == SBI_EXT_DEBUG_CONSOLE &&
              f->a6 == SBI_FUNC_DEBUG_CONSOLE_PUTCHAR &&
              f->a0 == '\n')) {
            printf("M trap from S ecall\n");
            printf("saved a7=%lx a6=%lx a0=%lx\n", f->a7, f->a6, f->a0);
        }
        firmware_handle_sbi(f);
        WRITE_CSR(mepc, mepc + 4);
        return;
    }

    PANIC("unexpected machine trap mcause=%lx", mcause);
}

void supervisor_trap_handler(struct trap_frame *f) {
    uintptr_t scause = READ_CSR(scause);
    uintptr_t sepc = READ_CSR(sepc);

    printf("S trap scause=%lx sepc=%lx\n", scause, sepc);
    printf("saved a0=%lx sp=%lx\n", f->a0, f->sp);

    if (scause == MCAUSE_ECALL_FROM_S) {
        __asm__ __volatile__(
            "csrr t0, sepc\n"
            "nop\n"
            "nop\n"
            "nop\n"
            "nop\n"
            "addi t0, t0, 4\n"
            "nop\n"
            "nop\n"
            "nop\n"
            "nop\n"
            "csrw sepc, t0\n"
            ::: "t0", "memory"
        );
        return;
    }

    if (scause == SCAUSE_SUPERVISOR_TIMER_INTERRUPT) {
        printf("S timer interrupt\n");
        WRITE_CSR(sip, READ_CSR(sip) & ~SIP_STIP);
        return;
    }

    PANIC("unexpected supervisor trap scause=%lx", scause);
}
