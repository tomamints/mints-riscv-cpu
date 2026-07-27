#define DEBUG_REG ((volatile unsigned long long *)0x40000000ULL)

#define UART_BASE 0x10000000ULL
#define UART_THR  0
#define UART_IER  1
#define UART_IIR  2

#define PLIC_BASE 0x0c000000ULL
#define PLIC_UART_IRQ 10

#define PLIC_PRIORITY(irq) (*(volatile unsigned int *)(PLIC_BASE + 0x000000ULL + 4ULL * (irq)))
#define PLIC_ENABLE_S     (*(volatile unsigned int *)(PLIC_BASE + 0x002080ULL))
#define PLIC_THRESHOLD_S  (*(volatile unsigned int *)(PLIC_BASE + 0x201000ULL))
#define PLIC_CLAIM_S      (*(volatile unsigned int *)(PLIC_BASE + 0x201004ULL))

#define PMP_R       (1ULL << 0)
#define PMP_W       (1ULL << 1)
#define PMP_X       (1ULL << 2)
#define PMP_A_NAPOT (3ULL << 3)

#define MSTATUS_MPP_MASK (3ULL << 11)
#define MSTATUS_MPP_S    (1ULL << 11)
#define MIDELEG_SEI      (1ULL << 9)
#define SSTATUS_SIE      (1ULL << 1)
#define SIE_SEIE         (1ULL << 9)
#define SCAUSE_SEI       (0x8000000000000009ULL)

static volatile unsigned char *const uart = (volatile unsigned char *)UART_BASE;
static volatile unsigned long trap_count;

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

void supervisor_trap_entry(void) {
    __asm__ volatile(
        "addi sp, sp, -16\n"
        "sd ra, 0(sp)\n"
        "call supervisor_trap_handler\n"
        "ld ra, 0(sp)\n"
        "addi sp, sp, 16\n"
        "sret\n"
    );
}

void supervisor_trap_handler(void) {
    unsigned long long scause = READ_CSR(scause);
    unsigned int claim;
    unsigned char iir;

    if (scause != SCAUSE_SEI) {
        fail();
    }

    claim = PLIC_CLAIM_S;
    if (claim != PLIC_UART_IRQ) {
        fail();
    }

    iir = uart[UART_IIR];
    if (iir != 0x02) {
        fail();
    }

    PLIC_CLAIM_S = claim;
    trap_count++;
}

void supervisor_main(void) {
    WRITE_CSR(stvec, (unsigned long long)supervisor_trap_entry);

    PLIC_PRIORITY(PLIC_UART_IRQ) = 1;
    PLIC_ENABLE_S = 1U << PLIC_UART_IRQ;
    PLIC_THRESHOLD_S = 0;

    WRITE_CSR(sie, READ_CSR(sie) | SIE_SEIE);
    WRITE_CSR(sstatus, READ_CSR(sstatus) | SSTATUS_SIE);

    uart[UART_IER] = 0x00;
    uart[UART_IER] = 0x02;

    wait_for_irq_count(1);

    uart[UART_THR] = 'A';
    wait_for_irq_count(2);

    uart[UART_THR] = 'B';
    wait_for_irq_count(3);

    uart[UART_THR] = '\n';
    wait_for_irq_count(4);

    put_debug_char('S');
    put_debug_char('\n');
    *DEBUG_REG = 1;
    while (1) {
    }
}

static void enter_supervisor(void (*entry)(void)) {
    unsigned long long mstatus = READ_CSR(mstatus);
    mstatus &= ~MSTATUS_MPP_MASK;
    mstatus |= MSTATUS_MPP_S;
    WRITE_CSR(mstatus, mstatus);
    WRITE_CSR(mepc, (unsigned long long)entry);
    __asm__ volatile("mret");
}

void main(void) {
    trap_count = 0;

    WRITE_CSR(pmpaddr0, ~0ULL);
    WRITE_CSR(pmpcfg0, PMP_R | PMP_W | PMP_X | PMP_A_NAPOT);
    WRITE_CSR(mideleg, READ_CSR(mideleg) | MIDELEG_SEI);

    enter_supervisor(supervisor_main);
    fail();
}
