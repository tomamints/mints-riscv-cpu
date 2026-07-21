#include "kernel.h"

extern char __bss[], __bss_end[], __stack_top[];

static volatile unsigned long long *const DEBUG_REG =
    (volatile unsigned long long *) 0x40000000ULL;

void putchar(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char) ch) | (0x01010ULL << 44);
}

long getchar(void) {
    unsigned long long value = *DEBUG_REG;
    if ((value & (0x01010ULL << 44)) == 0)
        return -1;
    return value & 0xff;
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
