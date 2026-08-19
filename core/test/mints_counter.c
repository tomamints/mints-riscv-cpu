#define DEBUG_REG ((volatile unsigned long long *)0x40000000ULL)

#ifndef BENCH_ITERATIONS
#define BENCH_ITERATIONS 10000ULL
#endif

static inline unsigned long long read_cycle(void) {
    unsigned long long value;
    __asm__ volatile("rdcycle %0" : "=r"(value));
    return value;
}

static inline unsigned long long read_instret(void) {
    unsigned long long value;
    __asm__ volatile("rdinstret %0" : "=r"(value));
    return value;
}

static void putchar_debug(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char)ch) | (0x01010ULL << 44);
}

static void puts_debug(const char *s) {
    while (*s) {
        putchar_debug(*s++);
    }
}

static void print_hex64(unsigned long long value) {
    static const char hex[] = "0123456789abcdef";

    puts_debug("0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        putchar_debug(hex[(value >> shift) & 0xf]);
    }
}

volatile unsigned long long mints_counter_sink;

void main(void) {
    unsigned long long acc = 0x123456789abcdef0ULL;

    unsigned long long cycle_start = read_cycle();
    unsigned long long instret_start = read_instret();

    for (unsigned long long i = 0; i < BENCH_ITERATIONS; ++i) {
        acc ^= i + 0x9e3779b97f4a7c15ULL;
        acc = (acc << 7) | (acc >> 57);
        acc += 0x100000001b3ULL;
    }

    unsigned long long instret_end = read_instret();
    unsigned long long cycle_end = read_cycle();

    mints_counter_sink = acc;

    puts_debug("[MINTS-BENCH] name=alu_loop iterations=");
    print_hex64(BENCH_ITERATIONS);
    puts_debug(" cycles=");
    print_hex64(cycle_end - cycle_start);
    puts_debug(" instret=");
    print_hex64(instret_end - instret_start);
    puts_debug(" result=");
    print_hex64(acc);
    putchar_debug('\n');

    *DEBUG_REG = 1;
}
