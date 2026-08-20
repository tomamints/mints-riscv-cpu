#define DEBUG_REG ((volatile unsigned long long *)0x40000000ULL)

#ifndef BENCH_ITERATIONS
#define BENCH_ITERATIONS 10000ULL
#endif

void mints_bench_alu_loop(unsigned long long iterations, unsigned long long *out);
void mints_bench_alu_loop_unroll2(unsigned long long iterations, unsigned long long *out);
void mints_bench_alu_loop_unroll4(unsigned long long iterations, unsigned long long *out);

static volatile unsigned long long bench_out[3][4];

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

static void print_result(const char *name, volatile unsigned long long *out) {
    puts_debug("[MINTS-ASM] name=");
    puts_debug(name);
    puts_debug(" iterations=");
    print_hex64(out[3]);
    puts_debug(" cycles=");
    print_hex64(out[0]);
    puts_debug(" instret=");
    print_hex64(out[1]);
    puts_debug(" result=");
    print_hex64(out[2]);
    putchar_debug('\n');
}

void main(void) {
    mints_bench_alu_loop(BENCH_ITERATIONS, (unsigned long long *)bench_out[0]);
    mints_bench_alu_loop_unroll2(BENCH_ITERATIONS, (unsigned long long *)bench_out[1]);
    mints_bench_alu_loop_unroll4(BENCH_ITERATIONS, (unsigned long long *)bench_out[2]);

    print_result("alu_loop_1x", bench_out[0]);
    print_result("alu_loop_2x", bench_out[1]);
    print_result("alu_loop_4x", bench_out[2]);

    *DEBUG_REG = 1;
}
