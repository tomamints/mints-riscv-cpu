#include "kernel.h"

struct sbiret sbi_call(long eid, long fid, long arg0) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = 0;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = eid;

    __asm__ __volatile__(
        "ecall"
        : "+r"(a0), "+r"(a1)
        : "r"(a6), "r"(a7)
        : "memory"
    );

    return (struct sbiret) { .error = a0, .value = a1 };
}

void sbi_putchar(char ch) {
    struct sbiret ret = sbi_call(
        SBI_EXT_DEBUG_CONSOLE,
        SBI_FUNC_DEBUG_CONSOLE_PUTCHAR,
        (unsigned char) ch
    );
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_putchar failed error=%ld", ret.error);
}

long sbi_getchar(void) {
    struct sbiret ret = sbi_call(
        SBI_EXT_DEBUG_CONSOLE,
        SBI_FUNC_DEBUG_CONSOLE_GETCHAR,
        0
    );
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_getchar failed error=%ld", ret.error);
    return ret.value;
}

struct sbiret sbi_set_timer(uint64_t stime_value) {
    return sbi_call(SBI_EXT_TIME, SBI_FUNC_TIME_SET_TIMER, (long) stime_value);
}
