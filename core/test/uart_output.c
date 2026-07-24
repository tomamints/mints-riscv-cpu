#define DEBUG_REG ((volatile unsigned long long*)0x40000000ULL)
#define UART_BASE 0x10000000ULL

static void uart_putchar(char ch) {
    volatile unsigned char *uart = (volatile unsigned char *)UART_BASE;

    while ((uart[5] & 0x20) == 0) {
    }

    uart[0] = (unsigned char)ch;
}

void main(void) {
    uart_putchar('A');
    uart_putchar('\n');
    *DEBUG_REG = 1;
}
