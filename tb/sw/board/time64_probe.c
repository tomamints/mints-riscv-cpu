#include <stdint.h>

/* M-mode timer CSR/MMIO width, rollover, monotonicity and compare probe. */
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

static uint64_t rdtime_(void) { uint64_t v; __asm__ volatile ("rdtime %0" : "=r"(v)); return v; }
static uint64_t rdcycle_(void) { uint64_t v; __asm__ volatile ("rdcycle %0" : "=r"(v)); return v; }
static uint64_t rdmip_(void) { uint64_t v; __asm__ volatile ("csrr %0, mip" : "=r"(v)); return v; }
static volatile uint64_t *const mtime_ = (volatile uint64_t *)0x0200bff8UL;
static volatile uint64_t *const mtimecmp_ = (volatile uint64_t *)0x02004000UL;
static void fail_(const char *label) { puts_("FAIL "); puts_(label); puts_("\n"); errors++; }
void main(void) {
    uart[3] = 0x83; uart[0] = 2; uart[1] = 0;
    uart[3] = 3; uart[2] = 7; uart[1] = 0;
    puts_("\nTIME64 PROBE\n");
    *mtimecmp_ = UINT64_MAX;
    const uint64_t seeds[] = {0x1122334455667700ULL, 0x00000002fffff000ULL, 0x8000000040000000ULL};
    for (unsigned j=0; j<3; j++) {
        *mtime_ = seeds[j];
        __asm__ volatile ("fence iorw, iorw" ::: "memory");
        uint64_t prev=rdtime_();
        if (prev < seeds[j] || prev-seeds[j] > 1000000) fail_("CSR high bits");
        for (unsigned i=0; i<1024; i++) {
            uint64_t now=rdtime_();
            if (now < prev) { fail_("monotonic"); break; }
            prev=now;
        }
        uint64_t mem=*mtime_;
        if (mem < prev || mem-prev > 100000) fail_("MMIO/CSR agreement");
        if (j==1 && prev < 0x0000000300000000ULL) fail_("low32 rollover not exercised");
        puts_("TIME64 sample "); hex_(prev); puts_("\n");
    }
    uint64_t c0=rdcycle_(), t0=rdtime_();
    for (unsigned i=0; i<1024; i++) __asm__ volatile ("nop");
    uint64_t t1=rdtime_(), c1=rdcycle_();
    uint64_t dc=c1-c0, dt=t1-t0;
    if (dc < dt || dc-dt > 4096 || !dt) fail_("time/cycle rate");
    puts_("TIME64 cycle_delta ");hex_(dc);puts_(" time_delta ");hex_(dt);puts_("\n");
    uint64_t seed=0x00000002fffff000ULL, deadline=seed+1000000;
    *mtime_ = seed; *mtimecmp_ = deadline;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    if (rdmip_() & 0x80) fail_("MTIP early");
    unsigned i;
    for (i=0; i<200000 && !(rdmip_() & 0x80); i++) {}
    if (i==200000 || rdtime_()<deadline) fail_("MTIP expiry");
    *mtimecmp_ = UINT64_MAX;
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
    if (rdmip_() & 0x80) fail_("MTIP clear");
    puts_(errors ? "TIME64 FAIL\n" : "TIME64 PASS\n");
    for (;;) __asm__ volatile ("wfi");
}
