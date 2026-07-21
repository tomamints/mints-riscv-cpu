#include "kernel.h"

extern char __bss[], __bss_end[], __stack_top[];

_Static_assert(offsetof(struct trap_frame, ra) == 0, "trap_frame ra offset");
_Static_assert(offsetof(struct trap_frame, a0) == 80, "trap_frame a0 offset");
_Static_assert(offsetof(struct trap_frame, s11) == 232, "trap_frame s11 offset");
_Static_assert(offsetof(struct trap_frame, sp) == 240, "trap_frame sp offset");
_Static_assert(sizeof(struct trap_frame) == 248, "trap_frame size");

static volatile unsigned long long *const DEBUG_REG =
    (volatile unsigned long long *) 0x40000000ULL;

void kernel_trap_entry(void);
void supervisor_main(void);

void putchar(char ch) {
    *DEBUG_REG = ((unsigned long long)(unsigned char) ch) | (0x01010ULL << 44); // 0x01010ULL << 44 は、デバッグレジスタの上位ビットに特定のフラグを設定するためのものです
}

long getchar(void) {
    unsigned long long value = *DEBUG_REG;
    if ((value & (0x01010ULL << 44)) == 0)
        return -1;
    return value & 0xff;
}

static long syscall(long sysno, long arg0) {
    register long a0 __asm__("a0") = sysno;
    register long a1 __asm__("a1") = arg0;

    __asm__ __volatile__(
        "ecall"
        : "+r"(a0)
        : "r"(a1)
        : "memory"
    );
    return a0;
}

static void enter_supervisor(void (*entry)(void)) {
    uintptr_t mstatus = READ_CSR(mstatus);

    mstatus &= ~(3UL << 11);
    mstatus |=  (1UL << 11); // MPP=S

    WRITE_CSR(mstatus, mstatus);
    WRITE_CSR(mepc, (uintptr_t) entry);
    __asm__ __volatile__("mret");
}

void kernel_trap_handler(struct trap_frame *f) {
    uintptr_t mcause = READ_CSR(mcause);
    uintptr_t mepc = READ_CSR(mepc);

    if (mcause == 11) {
        if (f->a0 == SYS_PUTCHAR) {
            putchar((char) f->a1);
            f->a0 = 0;
        } else {
            printf("trap mcause=%lx mepc=%lx\n", mcause, mepc);
            printf("machine ecall handled\n");
            printf("saved a0=%lx sp=%lx\n", f->a0, f->sp);
            f->a0 = -1;
        }
        WRITE_CSR(mepc, mepc + 4);
        return;
    }

    PANIC("unexpected trap mcause=%lx", mcause);
}

__attribute__((naked))
__attribute__((aligned(4)))
void kernel_trap_entry(void) {
    __asm__ __volatile__(
        "addi sp, sp, -256\n"
        "sd ra, 0(sp)\n"
        "sd gp, 8(sp)\n"
        "sd tp, 16(sp)\n"
        "sd t0, 24(sp)\n"
        "sd t1, 32(sp)\n"
        "sd t2, 40(sp)\n"
        "sd t3, 48(sp)\n"
        "sd t4, 56(sp)\n"
        "sd t5, 64(sp)\n"
        "sd t6, 72(sp)\n"
        "sd a0, 80(sp)\n"
        "sd a1, 88(sp)\n"
        "sd a2, 96(sp)\n"
        "sd a3, 104(sp)\n"
        "sd a4, 112(sp)\n"
        "sd a5, 120(sp)\n"
        "sd a6, 128(sp)\n"
        "sd a7, 136(sp)\n"
        "sd s0, 144(sp)\n"
        "sd s1, 152(sp)\n"
        "sd s2, 160(sp)\n"
        "sd s3, 168(sp)\n"
        "sd s4, 176(sp)\n"
        "sd s5, 184(sp)\n"
        "sd s6, 192(sp)\n"
        "sd s7, 200(sp)\n"
        "sd s8, 208(sp)\n"
        "sd s9, 216(sp)\n"
        "sd s10, 224(sp)\n"
        "sd s11, 232(sp)\n"
        "addi t0, sp, 256\n"
        "sd t0, 240(sp)\n"
        "mv a0, sp\n"
        "call kernel_trap_handler\n"
        "ld ra, 0(sp)\n"
        "ld gp, 8(sp)\n"
        "ld tp, 16(sp)\n"
        "ld t0, 24(sp)\n"
        "ld t1, 32(sp)\n"
        "ld t2, 40(sp)\n"
        "ld t3, 48(sp)\n"
        "ld t4, 56(sp)\n"
        "ld t5, 64(sp)\n"
        "ld t6, 72(sp)\n"
        "ld a0, 80(sp)\n"
        "ld a1, 88(sp)\n"
        "ld a2, 96(sp)\n"
        "ld a3, 104(sp)\n"
        "ld a4, 112(sp)\n"
        "ld a5, 120(sp)\n"
        "ld a6, 128(sp)\n"
        "ld a7, 136(sp)\n"
        "ld s0, 144(sp)\n"
        "ld s1, 152(sp)\n"
        "ld s2, 160(sp)\n"
        "ld s3, 168(sp)\n"
        "ld s4, 176(sp)\n"
        "ld s5, 184(sp)\n"
        "ld s6, 192(sp)\n"
        "ld s7, 200(sp)\n"
        "ld s8, 208(sp)\n"
        "ld s9, 216(sp)\n"
        "ld s10, 224(sp)\n"
        "ld s11, 232(sp)\n"
        "ld sp, 240(sp)\n"
        "mret\n"
    );
}

void supervisor_main(void) {
    printf("entered S-mode\n");
    printf("sstatus=%lx\n", READ_CSR(sstatus));
    *DEBUG_REG = 1;
    for (;;);
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
    if (syscall(SYS_PUTCHAR, 'S') != 0)
        PANIC("SYS_PUTCHAR failed");
    if (syscall(SYS_PUTCHAR, 'Y') != 0)
        PANIC("SYS_PUTCHAR failed");
    if (syscall(SYS_PUTCHAR, 'S') != 0)
        PANIC("SYS_PUTCHAR failed");
    if (syscall(SYS_PUTCHAR, '\n') != 0)
        PANIC("SYS_PUTCHAR failed");
    printf("returned from trap\n");
#elif defined(OS2_MIN_SMODE)
    printf("OS2 min S-mode test\n");
    enter_supervisor(supervisor_main);
    PANIC("returned from enter_supervisor");
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
