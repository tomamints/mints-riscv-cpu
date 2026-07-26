#define DEBUG_REG ((volatile unsigned long long *)0x40000000ULL)

static void fail(unsigned long long code) {
    *DEBUG_REG = 0xBAD00001ULL | (code << 1);
    while (1) {
    }
}

void main(void) {
    unsigned long long size = 0x200000ULL;
    unsigned long long divisor = 1024ULL;
    unsigned long long quotient;
    unsigned long long remainder;
    unsigned long long product;
    unsigned int sf_cap;
    unsigned int j = 0;

    __asm__ volatile("mul %0, %1, %2" : "=r"(product) : "r"(1ULL), "r"(size));
    if (product != 0x200000ULL) {
        fail(8);
    }

    __asm__ volatile("divu %0, %1, %2" : "=r"(quotient) : "r"(size), "r"(divisor));
    __asm__ volatile("remu %0, %1, %2" : "=r"(remainder) : "r"(size), "r"(divisor));

    if (quotient != 2048ULL) {
        fail(1);
    }
    if (remainder != 0ULL) {
        fail(2);
    }

    size = quotient;
    __asm__ volatile("divu %0, %1, %2" : "=r"(quotient) : "r"(size), "r"(divisor));
    __asm__ volatile("remu %0, %1, %2" : "=r"(remainder) : "r"(size), "r"(divisor));

    if (quotient != 2ULL) {
        fail(3);
    }
    if (remainder != 0ULL) {
        fail(4);
    }

    sf_cap = (unsigned int)quotient;
    while (sf_cap * 10U < 1000U) {
        sf_cap *= 10U;
        j++;
        if (j > 8U) {
            fail(5);
        }
    }

    if (sf_cap != 200U) {
        fail(6);
    }
    if (j != 2U) {
        fail(7);
    }

    *DEBUG_REG = 1;
}
