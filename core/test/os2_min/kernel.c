#include "kernel.h"

extern char __bss[], __bss_end[], __stack_top[];

static volatile unsigned long long *const DEBUG_REG =
    (volatile unsigned long long *) 0x40000000ULL;

void kernel_trap_entry(void);

void putchar(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char) ch) | (0x01010ULL << 44);
}

long getchar(void) {
    unsigned long long value = *DEBUG_REG;
    if ((value & (0x01010ULL << 44)) == 0)
        return -1;
    return value & 0xff;
}

uintptr_t kernel_trap_handler(uintptr_t mcause, uintptr_t mepc) {
    printf("trap mcause=%lx mepc=%lx\n", mcause, mepc);

    if (mcause == 11) {
        printf("machine ecall handled\n");
        return mepc + 4;
    }

    PANIC("unexpected trap mcause=%lx", mcause);
}

__attribute__((naked))
__attribute__((aligned(4)))
void kernel_trap_entry(void) {
    __asm__ __volatile__(
        "addi sp, sp, -16\n"
        "sd ra, 0(sp)\n"
        "csrr a0, mcause\n"
        "csrr a1, mepc\n"
        "call kernel_trap_handler\n"
        "csrw mepc, a0\n"
        "ld ra, 0(sp)\n"
        "addi sp, sp, 16\n"
        "mret\n"
    );
}

void kernel_main(void) {
    memset(__bss, 0, (size_t) __bss_end - (size_t) __bss);

#ifdef OS2_MIN_ECHO
    printf("OS2 min echo ready\n");
    long ch;
    do {
        ch = getchar();
    } while (ch < 0);

    printf("input=");
    putchar((char) ch);
    putchar('\n');
#elif defined(OS2_MIN_TRAP)
    printf("OS2 min trap test\n");
    WRITE_CSR(mtvec, (uintptr_t) kernel_trap_entry);
    __asm__ __volatile__("ecall");
    printf("returned from trap\n");
#else
    printf("Hello from MiNTsOS min on my CPU\n");
    printf("0x%x\n", 0x1234abcd);
    printf("kernel base=%lx\n", (uintptr_t) 0x80000000UL);
    printf("%s is coming\n", "Toma");
    printf("%d\n", -11111111);

    if (!strcmp("test2", "test"))
        printf("s1 == s2\n");
    else
        printf("s1 != s2\n");
#endif

    *DEBUG_REG = 1;
    for (;;);
}

__attribute__((section(".text.boot")))
__attribute__((naked))
void boot(void) {
    __asm__ __volatile__(
        "mv sp, %[stack_top]\n"
        "j kernel_main\n"
        :
        : [stack_top] "r" (__stack_top)
    );
}
