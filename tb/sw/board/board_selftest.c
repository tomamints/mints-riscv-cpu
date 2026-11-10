/*
 * DE0-CV bare-metal self test (loaded at 0x80000000 by de0cv-jtag-load,
 * entered from the Linux boot ROM). Reports on the physical UART
 * (ns16550 at 0x10000000, 115200 8N1 from the 3.6864 MHz reference):
 *   1. banner
 *   2. SDRAM: address, inverted-address and byte-lane patterns over all RAM
 *      above the first MiB (the program image/stack live below it)
 *   3. machine timer interrupts (ACLINT mtimecmp, 10 ticks at 10 Hz)
 *   (SELFTEST_SIM_QUICK: 64 KiB window and 1 kHz ticks for simulation)
 *   4. echo: every received byte is sent back (letters case-swapped)
 * Each step prints PASS or FAIL; the final line is "SELFTEST PASS" or
 * "SELFTEST FAIL" before the echo loop.
 */
#include <stdint.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define MTIMECMP ((volatile uint64_t *)0x02004000UL)
#define MTIME ((volatile uint64_t *)0x0200bff8UL)
#define RAM_BEGIN 0x80000000UL
#define TEST_BEGIN (RAM_BEGIN + 0x100000UL)
#define TIMEBASE_HZ 20000000UL
#ifdef SELFTEST_SIM_QUICK
/* simulation variant: 64 KiB SDRAM window, 1 kHz ticks */
#define RAM_END (TEST_BEGIN + 0x10000UL)
#define TICK_HZ 1000UL
#else
#define RAM_END 0x84000000UL
#define TICK_HZ 10UL
#endif

static void putc_(char c) {
    while ((UART[5] & 0x20) == 0) {
    }
    UART[0] = (uint8_t)c;
}
static void puts_(const char *s) {
    for (; *s; s++) {
        if (*s == '\n') putc_('\r');
        putc_(*s);
    }
}
static void puthex(uint64_t v) {
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 15]);
}
static void putdec(uint64_t v) {
    char b[24];
    int n = 0;
    do { b[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) putc_(b[--n]);
}

static int fail_report(const char *what, uint64_t addr, uint64_t got, uint64_t want) {
    puts_("  FAIL ");
    puts_(what);
    puts_(" at ");
    puthex(addr);
    puts_(" got ");
    puthex(got);
    puts_(" want ");
    puthex(want);
    puts_("\n");
    return 1;
}

static int sdram_test(void) {
    volatile uint64_t *p;
    int errors = 0;
    puts_("SDRAM ");
    puthex(TEST_BEGIN);
    puts_("..");
    puthex(RAM_END);
    puts_("\n");
    for (int pass = 0; pass < 2 && !errors; pass++) {
        uint64_t inv = pass ? ~0UL : 0;
        for (p = (volatile uint64_t *)TEST_BEGIN; p < (volatile uint64_t *)RAM_END; p++)
            *p = ((uint64_t)p * 0x9e3779b97f4a7c15UL) ^ inv;
        for (p = (volatile uint64_t *)TEST_BEGIN; p < (volatile uint64_t *)RAM_END; p++) {
            uint64_t want = ((uint64_t)p * 0x9e3779b97f4a7c15UL) ^ inv;
            uint64_t got = *p;
            if (got != want && errors++ < 8) fail_report("word", (uint64_t)p, got, want);
        }
        puts_(pass ? "  inverted pattern done\n" : "  address pattern done\n");
    }
    /* byte and halfword lanes inside a word, then read back as words */
    for (uint64_t a = TEST_BEGIN; a < TEST_BEGIN + 4096 && !errors; a += 8) {
        volatile uint8_t *b = (volatile uint8_t *)a;
        volatile uint16_t *h = (volatile uint16_t *)a;
        *(volatile uint64_t *)a = 0;
        b[1] = 0x5a;
        h[2] = 0xa55a;
        b[7] = 0xc3;
        uint64_t want = 0xc300a55a00005a00UL, got = *(volatile uint64_t *)a;
        if (got != want) errors += fail_report("lanes", a, got, want);
    }
    puts_(errors ? "SDRAM FAIL\n" : "SDRAM PASS\n");
    return errors;
}

static volatile uint64_t ticks;
static volatile uint64_t bad_trap;

void __attribute__((interrupt("machine"), aligned(4))) trap_handler(void) {
    uint64_t cause;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause == ((1UL << 63) | 7)) {
        ticks++;
        *MTIMECMP = *MTIME + TIMEBASE_HZ / TICK_HZ;
    } else {
        bad_trap = cause;
        *MTIMECMP = ~0UL;
        __asm__ volatile("csrc mie, %0" :: "r"(1UL << 7));
        uint64_t epc;
        __asm__ volatile("csrr %0, mepc" : "=r"(epc));
        if (!(cause >> 63)) __asm__ volatile("csrw mepc, %0" :: "r"(epc + 4));
    }
}

static int timer_test(void) {
    puts_("TIMER 10 ticks at ");
    putdec(TICK_HZ);
    puts_(" Hz\n");
    __asm__ volatile("csrw mtvec, %0" :: "r"((uint64_t)trap_handler));
    uint64_t start = *MTIME;
    *MTIMECMP = start + TIMEBASE_HZ / TICK_HZ;
    __asm__ volatile("csrs mie, %0" :: "r"(1UL << 7));
    __asm__ volatile("csrs mstatus, %0" :: "r"(1UL << 3));
    uint64_t span = 10 * TIMEBASE_HZ / TICK_HZ;
    while (ticks < 10 && !bad_trap && *MTIME - start < 3 * span) {
    }
    __asm__ volatile("csrc mstatus, %0" :: "r"(1UL << 3));
    __asm__ volatile("csrc mie, %0" :: "r"(1UL << 7));
    uint64_t elapsed = *MTIME - start;
    puts_("  ticks=");
    putdec(ticks);
    puts_(" elapsed_mtime=");
    putdec(elapsed);
    puts_("\n");
    /* 10 tick periods of mtime, plus handler latency (under 10 %) */
    int ok = !bad_trap && ticks == 10 && elapsed >= span && elapsed < span + span / 10;
    if (bad_trap) {
        puts_("  unexpected mcause ");
        puthex(bad_trap);
        puts_("\n");
    }
    puts_(ok ? "TIMER PASS\n" : "TIMER FAIL\n");
    return !ok;
}

void main(void) {
    UART[3] = 0x83; /* DLAB */
    UART[0] = 2;    /* 3.6864 MHz / (16 * 2) = 115200 */
    UART[1] = 0;
    UART[3] = 0x03; /* 8N1 */
    UART[2] = 0x07; /* FIFO enable + reset */
    UART[1] = 0;    /* no UART interrupts */
    puts_("\nMiNTs DE0-CV bare-metal self test\n");
    int errors = sdram_test();
    errors += timer_test();
    puts_(errors ? "SELFTEST FAIL\n" : "SELFTEST PASS\n");
    puts_("echo mode (letters case-swapped)\n");
    for (;;) {
        if (UART[5] & 1) {
            char c = (char)UART[0];
            if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) c ^= 0x20;
            putc_(c);
        }
    }
}
