#define DEBUG_REG ((volatile unsigned long long*)0x40000000ULL)
#define UART_BASE 0x10000000ULL

#define UART_RBR_THR_DLL 0
#define UART_IER_DLM     1
#define UART_IIR_FCR     2
#define UART_LCR         3
#define UART_MCR         4
#define UART_LSR         5
#define UART_MSR         6
#define UART_SCR         7

#define UART_LCR_DLAB 0x80
#define UART_LSR_DR   0x01
#define UART_LSR_THRE 0x20
#define UART_LSR_TEMT 0x40

static volatile unsigned char *const uart = (volatile unsigned char *)UART_BASE;

static void fail(void) {
    *DEBUG_REG = 2;
    while (1) {
    }
}

static void expect_eq(unsigned char actual, unsigned char expected) {
    if (actual != expected) {
        fail();
    }
}

static void expect_bits(unsigned char actual, unsigned char mask, unsigned char expected) {
    if ((actual & mask) != expected) {
        fail();
    }
}

void main(void) {
    expect_bits(uart[UART_LSR], UART_LSR_THRE | UART_LSR_TEMT | UART_LSR_DR, UART_LSR_THRE | UART_LSR_TEMT);
    expect_eq(uart[UART_IIR_FCR], 0x01);
    expect_eq(uart[UART_MSR], 0x00);

    uart[UART_IER_DLM] = 0x55;
    expect_eq(uart[UART_IER_DLM], 0x55);

    uart[UART_MCR] = 0x1b;
    expect_eq(uart[UART_MCR], 0x1b);

    uart[UART_SCR] = 0xa5;
    expect_eq(uart[UART_SCR], 0xa5);

    uart[UART_LCR] = UART_LCR_DLAB | 0x03;
    expect_eq(uart[UART_LCR], UART_LCR_DLAB | 0x03);

    uart[UART_RBR_THR_DLL] = 0x34;
    uart[UART_IER_DLM] = 0x12;
    expect_eq(uart[UART_RBR_THR_DLL], 0x34);
    expect_eq(uart[UART_IER_DLM], 0x12);

    uart[UART_LCR] = 0x03;
    expect_eq(uart[UART_LCR], 0x03);
    expect_eq(uart[UART_IER_DLM], 0x55);
    expect_eq(uart[UART_RBR_THR_DLL], 0x00);

    uart[UART_RBR_THR_DLL] = 'R';
    uart[UART_RBR_THR_DLL] = '\n';

    *DEBUG_REG = 1;
}
