#include <stdint.h>

/* Run in M-mode before OpenSBI. Tests the upper halves of CSR masks that
 * Quartus 20.1 can truncate when HDL hexadecimal literals have no size. */
static volatile uint8_t *const uart = (volatile uint8_t *)0x10000000UL;
static unsigned errors;

static void putc_(char c) {
    while (!(uart[5] & 0x20)) {}
    uart[0] = (uint8_t)c;
}
static void puts_(const char *s) {
    while (*s) {
        if (*s == '\n') putc_('\r');
        putc_(*s++);
    }
}
static void hex_(uint64_t v) {
    for (int shift = 60; shift >= 0; shift -= 4) {
        unsigned n = (unsigned)(v >> shift) & 15;
        putc_((char)(n < 10 ? '0' + n : 'a' + n - 10));
    }
}
static void check(const char *name, uint64_t got, uint64_t expected) {
    puts_(name); putc_(' '); hex_(got);
    if (got != expected) {
        puts_(" FAIL expected "); hex_(expected); errors++;
    }
    putc_('\n');
}
#define CHECK_CSR(csr, value, expected) do { \
    uint64_t v_ = (value), r_; \
    __asm__ volatile ("csrw " #csr ", %0" :: "r"(v_) : "memory"); \
    __asm__ volatile ("csrr %0, " #csr : "=r"(r_) :: "memory"); \
    check(#csr, r_, (expected)); \
} while (0)

void main(void) {
    uart[3] = 0x83; uart[0] = 2; uart[1] = 0;
    uart[3] = 3; uart[2] = 7; uart[1] = 0;
    puts_("\nCSR WIDTH PROBE\n");
    CHECK_CSR(pmpaddr0, UINT64_MAX, 0x003fffffffffffffULL);
    CHECK_CSR(pmpaddr7, UINT64_MAX, 0x003fffffffffffffULL);
    CHECK_CSR(pmpcfg0, 0x1f1f1f1f1f1f1f1fULL, 0x1f1f1f1f1f1f1f1fULL);
    CHECK_CSR(satp, 0x8000000000080200ULL, 0x8000000000080200ULL);
    __asm__ volatile ("csrw satp, zero" ::: "memory");
    CHECK_CSR(sscratch, 0x123456789abcdef0ULL, 0x123456789abcdef0ULL);
    CHECK_CSR(mepc, 0xffffffff80201000ULL, 0xffffffff80201000ULL);
    CHECK_CSR(stvec, 0xffffffff80202000ULL, 0xffffffff80202000ULL);
    uint64_t status;
    __asm__ volatile ("csrr %0, sstatus" : "=r"(status));
    check("sstatus.UXL", status & 0x300000000ULL, 0x200000000ULL);
    puts_(errors ? "CSR WIDTH FAIL\n" : "CSR WIDTH PASS\n");
    for (;;) __asm__ volatile ("wfi");
}
