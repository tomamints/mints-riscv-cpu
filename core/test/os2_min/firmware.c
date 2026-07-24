#include "kernel.h"

void firmware_handle_sbi(struct trap_frame *f) {
    if (f->a7 == SBI_EXT_DEBUG_CONSOLE) {
        if (f->a6 == SBI_FUNC_DEBUG_CONSOLE_PUTCHAR) {
            platform_putchar((char) f->a0);
            f->a0 = SBI_SUCCESS;
            f->a1 = 0;
            return;
        }

        if (f->a6 == SBI_FUNC_DEBUG_CONSOLE_GETCHAR) {
            f->a0 = SBI_SUCCESS;
            f->a1 = platform_getchar();
            return;
        }
    }

    if (f->a7 == SBI_EXT_TIME && f->a6 == SBI_FUNC_TIME_SET_TIMER) {
        platform_set_timer((uint64_t) f->a0);
        f->a0 = SBI_SUCCESS;
        f->a1 = 0;
        return;
    }

#ifdef OS2_MIN_PMP
    if (f->a7 == SBI_EXT_TEST && f->a6 == SBI_FUNC_TEST_READ_PMP_WORD) {
        f->a0 = SBI_SUCCESS;
        f->a1 = (long) pmp_protected_word;
        return;
    }

    if (f->a7 == SBI_EXT_TEST && f->a6 == SBI_FUNC_TEST_ALLOW_EXEC_ONLY_TARGET) {
        uintptr_t protected_start = (uintptr_t) pmp_protected_exec_target;
        uintptr_t protected_end = protected_start + 8;
        WRITE_CSR(pmpcfg0, 0);
        WRITE_CSR(pmpaddr0, protected_start >> 2);
        WRITE_CSR(pmpaddr1, protected_end >> 2);
        WRITE_CSR(pmpaddr2, ~0UL);
        WRITE_CSR(pmpcfg0, ((PMP_X | PMP_A_TOR) << 8) | ((PMP_R | PMP_W | PMP_X | PMP_A_NAPOT) << 16));
        f->a0 = SBI_SUCCESS;
        f->a1 = 0;
        return;
    }

    if (f->a7 == SBI_EXT_TEST && f->a6 == SBI_FUNC_TEST_PROTECT_EXEC_TARGET) {
        uintptr_t protected_start = (uintptr_t) pmp_protected_exec_target;
        uintptr_t protected_end = protected_start + 8;
        WRITE_CSR(pmpcfg0, 0);
        WRITE_CSR(pmpaddr0, protected_start >> 2);
        WRITE_CSR(pmpaddr1, protected_end >> 2);
        WRITE_CSR(pmpaddr2, ~0UL);
        WRITE_CSR(pmpcfg0, ((PMP_R | PMP_W | PMP_A_TOR) << 8) | ((PMP_R | PMP_W | PMP_X | PMP_A_NAPOT) << 16));
        f->a0 = SBI_SUCCESS;
        f->a1 = 0;
        return;
    }

    if (f->a7 == SBI_EXT_TEST && f->a6 == SBI_FUNC_TEST_PROTECT_CROSS_EXEC_TARGET) {
        uintptr_t protected_start = (uintptr_t) pmp_cross_exec_target + 2;
        uintptr_t protected_end = protected_start + 4;
        WRITE_CSR(pmpcfg0, 0);
        WRITE_CSR(pmpaddr0, protected_start >> 2);
        WRITE_CSR(pmpaddr1, protected_end >> 2);
        WRITE_CSR(pmpaddr2, ~0UL);
        WRITE_CSR(pmpcfg0, ((PMP_R | PMP_W | PMP_A_TOR) << 8) | ((PMP_R | PMP_W | PMP_X | PMP_A_NAPOT) << 16));
        f->a0 = SBI_SUCCESS;
        f->a1 = 0;
        return;
    }
#endif

    f->a0 = SBI_ERR_NOT_SUPPORTED;
    f->a1 = 0;
}
