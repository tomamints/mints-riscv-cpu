#define DEBUG_REG ((volatile unsigned long long*)0x40000000ULL)
#define UART_BASE 0x10000000ULL

#define UART_RBR_THR_DLL 0
#define UART_LSR         5

#define UART_LSR_DR   0x01
#define UART_LSR_THRE 0x20

static volatile unsigned char *const uart = (volatile unsigned char *)UART_BASE;

static void uart_putchar(char ch) {
    while ((uart[UART_LSR] & UART_LSR_THRE) == 0) {
    }
    uart[UART_RBR_THR_DLL] = (unsigned char)ch;
}

void main(void) {
    unsigned char ch;

    while ((uart[UART_LSR] & UART_LSR_DR) == 0) {
    }

    ch = uart[UART_RBR_THR_DLL];
    uart_putchar(ch);
    uart_putchar('\n');

    if (ch == 'Z') {
        *DEBUG_REG = 1;
    } else {
        *DEBUG_REG = 2;
    }
}
