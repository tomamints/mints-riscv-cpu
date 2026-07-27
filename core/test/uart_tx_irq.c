#define DEBUG_REG ((volatile unsigned long long *)0x40000000ULL)

#define UART_BASE 0x10000000ULL
#define UART_THR  0
#define UART_IER  1
#define UART_IIR  2

#define PLIC_BASE 0x0c000000ULL
#define PLIC_UART_IRQ 10

#define PLIC_PRIORITY(irq) (*(volatile unsigned int *)(PLIC_BASE + 0x000000ULL + 4ULL * (irq)))
#define PLIC_ENABLE_M     (*(volatile unsigned int *)(PLIC_BASE + 0x002000ULL))
#define PLIC_THRESHOLD_M  (*(volatile unsigned int *)(PLIC_BASE + 0x200000ULL))
#define PLIC_CLAIM_M      (*(volatile unsigned int *)(PLIC_BASE + 0x200004ULL))

#define MSTATUS_MIE (1ULL << 3)
#define MIE_MEIE    (1ULL << 11)
#define MCAUSE_MEI  (0x800000000000000bULL)

static volatile unsigned char *const uart = (volatile unsigned char *)UART_BASE;
static volatile unsigned long trap_count;
static volatile unsigned long long saved_mcause;
static volatile unsigned int saved_claim;
static volatile unsigned char saved_iir;

#define READ_CSR(name) ({ \
    unsigned long long value; \
    __asm__ volatile("csrr %0, " #name : "=r"(value)); \
    value; \
})

#define WRITE_CSR(name, value) \
    __asm__ volatile("csrw " #name ", %0" :: "r"(value))

static void put_debug_char(char ch) {
    *DEBUG_REG = 0x0101000000000000ULL | (unsigned char)ch;
}

static void fail(void) {
    put_debug_char('F');
    *DEBUG_REG = 2;
    while (1) {
    }
}

static void wait_for_irq_count(unsigned long expected) {
    for (volatile unsigned long i = 0; i < 100000UL && trap_count < expected; i++) {
    }

    if (trap_count < expected) {
        fail();
    }
}

void machine_trap_entry(void) {
    __asm__ volatile(
        "addi sp, sp, -16\n"
        "sd ra, 0(sp)\n"
        "call machine_trap_handler\n"
        "ld ra, 0(sp)\n"
        "addi sp, sp, 16\n"
        "mret\n"
    );
}

void machine_trap_handler(void) {
    saved_mcause = READ_CSR(mcause);
    if (saved_mcause != MCAUSE_MEI) {
        fail();
    }

    saved_claim = PLIC_CLAIM_M;
    if (saved_claim != PLIC_UART_IRQ) {
        fail();
    }

    saved_iir = uart[UART_IIR];
    if (saved_iir != 0x02) {
        fail();
    }

    PLIC_CLAIM_M = saved_claim;
    trap_count++;
}

void main(void) {
    trap_count = 0;
    saved_mcause = 0;
    saved_claim = 0;
    saved_iir = 0;

    WRITE_CSR(mtvec, (unsigned long long)machine_trap_entry);

    PLIC_PRIORITY(PLIC_UART_IRQ) = 1;
    PLIC_ENABLE_M = 1U << PLIC_UART_IRQ;
    PLIC_THRESHOLD_M = 0;

    uart[UART_IER] = 0x00;
    uart[UART_IER] = 0x02;

    WRITE_CSR(mie, READ_CSR(mie) | MIE_MEIE);
    WRITE_CSR(mstatus, READ_CSR(mstatus) | MSTATUS_MIE);

    wait_for_irq_count(1);

    uart[UART_THR] = 'A';
    wait_for_irq_count(2);

    uart[UART_THR] = 'B';
    wait_for_irq_count(3);

    uart[UART_THR] = '\n';
    wait_for_irq_count(4);

    put_debug_char('P');
    put_debug_char('\n');
    *DEBUG_REG = 1;
}
