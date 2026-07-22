#include "kernel.h"

void putchar(char ch);

void kernel_trap_handler(struct trap_frame *f) {
    uintptr_t mcause = READ_CSR(mcause);
    uintptr_t mepc = READ_CSR(mepc);

    if (mcause == MCAUSE_ECALL_FROM_M) {
        if (f->a0 == SYS_PUTCHAR) {
            putchar((char) f->a1);
            f->a0 = 0;
        } else {
            printf("trap mcause=%lx mepc=%lx\n", mcause, mepc);
            printf("machine ecall handled\n");
            printf("saved a0=%lx sp=%lx\n", f->a0, f->sp);
            f->a0 = -1;
        }
        WRITE_CSR(mepc, mepc + 4);
        return;
    }

    if (mcause == MCAUSE_ECALL_FROM_S) {
        printf("M trap from S ecall\n");
        printf("saved a7=%lx a6=%lx a0=%lx\n", f->a7, f->a6, f->a0);

        if (f->a7 == SBI_EXT_DEBUG_CONSOLE &&
            f->a6 == SBI_FUNC_DEBUG_CONSOLE_PUTCHAR) {
            putchar((char) f->a0);
            f->a0 = 0;
            f->a1 = 0;
        } else {
            f->a0 = -1;
            f->a1 = 0;
        }

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

    PANIC("unexpected supervisor trap scause=%lx", scause);
}
