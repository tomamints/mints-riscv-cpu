typedef unsigned long uint64_t;

#define DEBUG_MMIO_BASE 0x40000000UL

struct sbiret {
    long error;
    long value;
};

static inline struct sbiret sbi_call(long arg0, long arg1, long arg2, long arg3,
                                     long arg4, long arg5, long fid, long eid) {
    register long a0 __asm__("a0") = arg0;
    register long a1 __asm__("a1") = arg1;
    register long a2 __asm__("a2") = arg2;
    register long a3 __asm__("a3") = arg3;
    register long a4 __asm__("a4") = arg4;
    register long a5 __asm__("a5") = arg5;
    register long a6 __asm__("a6") = fid;
    register long a7 __asm__("a7") = eid;

    __asm__ __volatile__(
        "ecall"
        : "+r"(a0), "+r"(a1)
        : "r"(a2), "r"(a3), "r"(a4), "r"(a5), "r"(a6), "r"(a7)
        : "memory");

    return (struct sbiret){.error = a0, .value = a1};
}

static void sbi_putchar(char ch) {
    sbi_call((long)ch, 0, 0, 0, 0, 0, 0, 0x01);
}

static void puts(const char *s) {
    while (*s)
        sbi_putchar(*s++);
}

static void puthex64(uint64_t value) {
    static const char digits[] = "0123456789abcdef";
    for (int shift = 60; shift >= 0; shift -= 4)
        sbi_putchar(digits[(value >> shift) & 0xf]);
}

static void sim_exit_success(void) {
    volatile uint64_t *debug = (volatile uint64_t *)DEBUG_MMIO_BASE;
    *debug = 1;
}

void payload_main(uint64_t hartid, uint64_t dtb_addr) {
    struct sbiret spec = sbi_call(0, 0, 0, 0, 0, 0, 0, 0x10);

    puts("\nOpenSBI S-mode payload reached\n");
    puts("hartid=0x");
    puthex64(hartid);
    puts(" dtb=0x");
    puthex64(dtb_addr);
    puts("\nSBI base spec=0x");
    puthex64((uint64_t)spec.value);
    puts(" error=0x");
    puthex64((uint64_t)spec.error);
    puts("\n");

    sim_exit_success();

    for (;;)
        __asm__ __volatile__("wfi");
}
