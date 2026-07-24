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
    uintptr_t stval = READ_CSR(stval);

#ifdef OS2_MIN_SV39
    uintptr_t noexec_target = (uintptr_t) sv39_noexec_target;
    uintptr_t noexec_page = noexec_target & ~(PAGE_SIZE - 1);
    if (scause == INSTRUCTION_PAGE_FAULT &&
        ((stval >= noexec_page && stval < noexec_page + PAGE_SIZE) ||
         (sepc >= noexec_page && sepc < noexec_page + PAGE_SIZE))) {
        sv39_fetch_fault_seen = 1;
        WRITE_CSR(sepc, f->ra);
        return;
    }
#endif

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

    if (scause == MCAUSE_ECALL_FROM_U) {
        umode_ecall_seen++;
        if (umode_ecall_seen == 1) {
            f->a0 = 0x5678;
            WRITE_CSR(sepc, sepc + 4);
            return;
        }
        if (umode_ecall_seen == 2 && umode_step == 2) {
            printf("U-mode ecall OK\n");
            platform_test_success();
            for (;;)
                ;
        }
    }

#ifdef OS2_MIN_PMP
    if (scause == LOAD_ACCESS_FAULT && stval == (uintptr_t) &pmp_protected_word) {
        printf("PMP load access fault stval=%lx\n", stval);
        pmp_load_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    if (scause == STORE_AMO_ACCESS_FAULT && stval == (uintptr_t) &pmp_protected_word) {
        printf("PMP store access fault stval=%lx\n", stval);
        pmp_store_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    uintptr_t exec_target = (uintptr_t) pmp_protected_exec_target;
    if (scause == INSTRUCTION_ACCESS_FAULT && stval >= exec_target && stval < exec_target + 8) {
        printf("PMP instruction access fault stval=%lx\n", stval);
        pmp_exec_fault_seen = 1;
        WRITE_CSR(sepc, f->ra);
        return;
    }
    uintptr_t cross_exec_target = (uintptr_t) pmp_cross_exec_target;
    uintptr_t cross_fetch_block = cross_exec_target & ~7UL;
    if (scause == INSTRUCTION_ACCESS_FAULT &&
        ((stval >= cross_fetch_block && stval < cross_fetch_block + 8) ||
         (sepc >= cross_fetch_block && sepc < cross_fetch_block + 8))) {
        printf("PMP cross instruction access fault stval=%lx\n", stval);
        pmp_cross_exec_fault_seen = 1;
        WRITE_CSR(sepc, f->ra);
        return;
    }
#endif

#ifdef OS2_MIN_SV39
    if (scause == LOAD_PAGE_FAULT && stval == 0x60000000UL) {
        printf("Sv39 load page fault stval=%lx\n", stval);
        sv39_load_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    if (scause == LOAD_PAGE_FAULT && stval == (uintptr_t) sv39_user_page) {
        printf("Sv39 SUM load page fault stval=%lx\n", stval);
        sv39_sum_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    if (scause == LOAD_PAGE_FAULT && stval == (uintptr_t) sv39_exec_page) {
        printf("Sv39 MXR load page fault stval=%lx\n", stval);
        sv39_mxr_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    if (scause == LOAD_PAGE_FAULT && stval == (uintptr_t) sv39_accessed_page) {
        printf("Sv39 A bit load page fault stval=%lx\n", stval);
        sv39_accessed_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
    if (scause == STORE_AMO_PAGE_FAULT && stval == (uintptr_t) sv39_dirty_page) {
        printf("Sv39 D bit store page fault stval=%lx\n", stval);
        sv39_dirty_fault_seen = 1;
        WRITE_CSR(sepc, sepc + 4);
        return;
    }
#endif

    if (scause == SCAUSE_SUPERVISOR_TIMER_INTERRUPT) {
        printf("S timer interrupt\n");
        WRITE_CSR(sip, READ_CSR(sip) & ~SIP_STIP);
        return;
    }

    PANIC("unexpected supervisor trap scause=%lx", scause);
}
