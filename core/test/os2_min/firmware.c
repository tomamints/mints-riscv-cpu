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
#endif

    f->a0 = SBI_ERR_NOT_SUPPORTED;
    f->a1 = 0;
}
