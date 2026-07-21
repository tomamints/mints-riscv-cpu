#include "common.h"

extern char __bss[], __bss_end[], __stack_top[];

static volatile unsigned long long *const DEBUG_REG =
    (volatile unsigned long long *) 0x40000000ULL;

void putchar(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char) ch) | (0x01010ULL << 44);
}

long getchar(void) {
    return -1;
}

void kernel_main(void) {
    memset(__bss, 0, (size_t) __bss_end - (size_t) __bss);

    printf("Hello from OS2 min on my CPU\n");
    printf("0x%x\n", 0x1234abcd);
    printf("%s is coming\n", "Toma");
    printf("%d\n", -11111111);

    if (!strcmp("test2", "test"))
        printf("s1 == s2\n");
    else
        printf("s1 != s2\n");

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
