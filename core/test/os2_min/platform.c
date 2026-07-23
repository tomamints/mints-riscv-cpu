#include "kernel.h"

static volatile unsigned long long *const DEBUG_REG =
    (volatile unsigned long long *) 0x40000000ULL;
static volatile unsigned long long *const ACLINT_MTIMECMP =
    (volatile unsigned long long *) 0x02004000ULL;
static volatile unsigned long long *const ACLINT_SETSTIP =
    (volatile unsigned long long *) 0x02008008ULL;

void platform_putchar(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char) ch) | (0x01010ULL << 44);
}

long platform_getchar(void) {
    unsigned long long value = *DEBUG_REG;
    if ((value & (0x01010ULL << 44)) == 0)
        return -1;
    return value & 0xff;
}

void platform_test_success(void) {
    *DEBUG_REG = 1;
}

void platform_set_timer(uint64_t stime_value) {
    *ACLINT_MTIMECMP = stime_value;
}

void platform_stop_timer(void) {
    *ACLINT_MTIMECMP = ~0ULL;
}

void platform_set_stip(void) {
    *ACLINT_SETSTIP = 1;
}

void putchar(char ch) {
    platform_putchar(ch);
}

long getchar(void) {
    return platform_getchar();
}
