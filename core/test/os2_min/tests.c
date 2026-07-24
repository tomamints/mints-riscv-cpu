#include "kernel.h"

volatile uint64_t pmp_protected_word __attribute__((aligned(8))) = 0x1122334455667788ULL;
volatile int pmp_load_fault_seen = -1;
volatile int pmp_store_fault_seen = -1;
volatile int pmp_exec_fault_seen = -1;
volatile int pmp_cross_exec_fault_seen = -1;
volatile int umode_step = -1;
volatile int umode_ecall_seen = -1;
volatile int sv39_load_fault_seen = -1;
volatile int sv39_sum_fault_seen = -1;
volatile int sv39_mxr_fault_seen = -1;

#define PMP_PROTECTED_WORD_INITIAL 0x1122334455667788ULL

#ifdef OS2_MIN_SV39
volatile uint64_t sv39_test_word __attribute__((aligned(8))) = 0x13579bdf2468ace0ULL;
volatile uint64_t sv39_user_page[512] __attribute__((aligned(PAGE_SIZE))) = {
    [0] = 0x123456789abcdef0ULL
};
volatile uint64_t sv39_exec_page[512] __attribute__((aligned(PAGE_SIZE))) = {
    [0] = 0xfeedfacecafebeefULL
};

static uint64_t sv39_root_pt[512] __attribute__((aligned(PAGE_SIZE)));
static uint64_t sv39_ram_l1[512] __attribute__((aligned(PAGE_SIZE)));
static uint64_t sv39_ram_l0[512] __attribute__((aligned(PAGE_SIZE)));
static uint64_t sv39_debug_l1[512] __attribute__((aligned(PAGE_SIZE)));
static uint64_t sv39_debug_l0[512] __attribute__((aligned(PAGE_SIZE)));

#define SV39_PTE_FLAGS (PAGE_V | PAGE_R | PAGE_W | PAGE_X | PAGE_A | PAGE_D)
#define SV39_DEBUG_ADDR 0x40000000UL
#define SV39_RAM_BASE 0x80000000UL
#define SV39_SUPERPAGE_ALIAS (SV39_RAM_BASE + 0x200000UL)
#define SV39_L2_SUPERPAGE_ALIAS 0xc0000000UL

static uint64_t sv39_make_pte(uintptr_t pa, uint64_t flags) {
    return ((pa >> 12) << 10) | flags;
}

static void sv39_map_page(uintptr_t va, uintptr_t pa, uint64_t flags) {
    uint64_t vpn2 = (va >> 30) & 0x1ff;
    uint64_t vpn1 = (va >> 21) & 0x1ff;
    uint64_t vpn0 = (va >> 12) & 0x1ff;
    uint64_t *l0;

    if (va >= SV39_RAM_BASE && va < SV39_RAM_BASE + 0x200000UL) {
        sv39_root_pt[vpn2] = sv39_make_pte((uintptr_t) sv39_ram_l1, PAGE_V);
        sv39_ram_l1[vpn1] = sv39_make_pte((uintptr_t) sv39_ram_l0, PAGE_V);
        l0 = sv39_ram_l0;
    } else if (va >= SV39_DEBUG_ADDR && va < SV39_DEBUG_ADDR + PAGE_SIZE) {
        sv39_root_pt[vpn2] = sv39_make_pte((uintptr_t) sv39_debug_l1, PAGE_V);
        sv39_debug_l1[vpn1] = sv39_make_pte((uintptr_t) sv39_debug_l0, PAGE_V);
        l0 = sv39_debug_l0;
    } else {
        PANIC("sv39_map_page unsupported va=%lx", va);
    }

    l0[vpn0] = sv39_make_pte(pa, flags);
}

static void sv39_build_identity_map(void) {
    memset(sv39_root_pt, 0, sizeof(sv39_root_pt));
    memset(sv39_ram_l1, 0, sizeof(sv39_ram_l1));
    memset(sv39_ram_l0, 0, sizeof(sv39_ram_l0));
    memset(sv39_debug_l1, 0, sizeof(sv39_debug_l1));
    memset(sv39_debug_l0, 0, sizeof(sv39_debug_l0));

    for (uintptr_t pa = SV39_RAM_BASE;
         pa < SV39_RAM_BASE + 0x200000UL;
         pa += PAGE_SIZE) {
        sv39_map_page(pa, pa, SV39_PTE_FLAGS);
    }
    sv39_map_page(SV39_DEBUG_ADDR, SV39_DEBUG_ADDR, PAGE_V | PAGE_R | PAGE_W | PAGE_A | PAGE_D);
}

static void sv39_remap_page(uintptr_t va, uint64_t flags) {
    sv39_map_page(va, va, flags);
    __asm__ __volatile__("sfence.vma" ::: "memory");
}

static void sv39_map_l1_superpage(uintptr_t va, uintptr_t pa, uint64_t flags) {
    uint64_t vpn2 = (va >> 30) & 0x1ff;
    uint64_t vpn1 = (va >> 21) & 0x1ff;

    sv39_root_pt[vpn2] = sv39_make_pte((uintptr_t) sv39_ram_l1, PAGE_V);
    sv39_ram_l1[vpn1] = sv39_make_pte(pa, flags);
    __asm__ __volatile__("sfence.vma" ::: "memory");
}

static void sv39_map_l2_superpage(uintptr_t va, uintptr_t pa, uint64_t flags) {
    uint64_t vpn2 = (va >> 30) & 0x1ff;

    sv39_root_pt[vpn2] = sv39_make_pte(pa, flags);
    __asm__ __volatile__("sfence.vma" ::: "memory");
}
#endif

__attribute__((noinline, aligned(8)))
void pmp_protected_exec_target(void) {
    __asm__ __volatile__("nop" ::: "memory");
}

__asm__(
    ".section .text\n"
    ".balign 4\n"
    ".2byte 0x0001\n"
    ".globl pmp_cross_exec_target\n"
    ".type pmp_cross_exec_target, @function\n"
    "pmp_cross_exec_target:\n"
    ".option push\n"
    ".option norvc\n"
    "addi zero, zero, 0\n"
    "jalr zero, 0(ra)\n"
    ".option pop\n"
    ".size pmp_cross_exec_target, .-pmp_cross_exec_target\n"
);

void test_smode_basic(void) {
    printf("entered S-mode\n");
    printf("sstatus=%lx\n", READ_CSR(sstatus));
}

void test_sbi_putchar(void) {
    printf("SBI putchar test\n");
    sbi_putchar('T');
    sbi_putchar('o');
    sbi_putchar('m');
    sbi_putchar('a');
    sbi_putchar('\n');
}

void test_sbi_getchar(void) {
    printf("SBI getchar test\n");
    long ch;
    do {
        ch = sbi_getchar();
    } while (ch < 0);
    printf("sbi input=");
    sbi_putchar((char) ch);
    sbi_putchar('\n');
}

void test_sbi_timer(void) {
    printf("SBI timer test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    WRITE_CSR(sie, READ_CSR(sie) | SIE_STIE); // SIE.STIEをセットして、S-modeでのタイマー割り込みを有効化
    WRITE_CSR(sstatus, READ_CSR(sstatus) | SSTATUS_SIE); // SSTATUS.SIEをセットして、S-modeでの割り込みを有効化
    for (int i = 0; i < 3; i++) {
        printf("timer wait %d\n", i);
        struct sbiret ret = sbi_set_timer(READ_CSR(time) + 10000);
        if (ret.error != SBI_SUCCESS)
            PANIC("sbi_set_timer failed error=%ld", ret.error);
        __asm__ __volatile__("wfi"); //wait for interruptで、割り込みが来るまで待機する
        printf("timer woke %d\n", i);
    }
}

void test_smode_trap(void) {
    printf("entered S-mode trap test\n");
    WRITE_CSR(sepc, 0x80000000UL);
    printf("probe sepc=%lx\n", READ_CSR(sepc));
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    __asm__ __volatile__("ecall");
    printf("returned from S trap\n");
}

void test_pmp_data_fault(void) {
    printf("PMP data fault test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);
    pmp_load_fault_seen = 0;
    __asm__ __volatile__("ld zero, 0(%0)" :: "r" (&pmp_protected_word) : "memory");
    if (!pmp_load_fault_seen)
        PANIC("PMP load fault was not raised");
    printf("PMP load fault OK\n");

    pmp_store_fault_seen = 0;
    __asm__ __volatile__("sd zero, 0(%0)" :: "r" (&pmp_protected_word) : "memory");
    if (!pmp_store_fault_seen)
        PANIC("PMP store fault was not raised");
    printf("PMP store fault OK\n");

    struct sbiret ret = sbi_test_read_pmp_word();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_read_pmp_word failed error=%ld", ret.error);
    if ((uint64_t) ret.value != PMP_PROTECTED_WORD_INITIAL)
        PANIC("PMP store changed protected word value=%lx", ret.value);
    printf("PMP store side effect blocked\n");

    ret = sbi_test_allow_exec_only_target();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_allow_exec_only_target failed error=%ld", ret.error);
    pmp_protected_exec_target();
    printf("PMP exec-only fetch OK\n");

    ret = sbi_test_protect_exec_target();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_protect_exec_target failed error=%ld", ret.error);
    pmp_exec_fault_seen = 0;
    pmp_protected_exec_target();
    if (!pmp_exec_fault_seen)
        PANIC("PMP exec fault was not raised");
    printf("PMP exec fault OK\n");

    ret = sbi_test_protect_cross_exec_target();
    if (ret.error != SBI_SUCCESS)
        PANIC("sbi_test_protect_cross_exec_target failed error=%ld", ret.error);
    pmp_cross_exec_fault_seen = 0;
    pmp_cross_exec_target();
    if (!pmp_cross_exec_fault_seen)
        PANIC("PMP cross exec fault was not raised");
    printf("PMP cross-boundary exec fault OK\n");
}

__attribute__((noreturn, noinline, aligned(4)))
void user_entry(void) {
    register long a0 __asm__("a0") = 0x1234;

    umode_step = 1;
    __asm__ __volatile__("ecall" : "+r"(a0) :: "memory");
    if (a0 == 0x5678)
        umode_step = 2;
    else
        umode_step = -2;

    __asm__ __volatile__("ecall" :: "r"(a0) : "memory");
    for (;;)
        ;
}

void test_umode_transition(void) {
    printf("U-mode transition test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);

    umode_step = 0;
    umode_ecall_seen = 0;

    uintptr_t sstatus = READ_CSR(sstatus);
    sstatus &= ~SSTATUS_SPP;
    sstatus |= SSTATUS_SPIE;
    WRITE_CSR(sstatus, sstatus);
    WRITE_CSR(sepc, (uintptr_t) user_entry);
    __asm__ __volatile__("sret");
    PANIC("returned from U-mode test");
}

void test_sv39_data_identity(void) {
#ifdef OS2_MIN_SV39
    printf("Sv39 data identity test\n");
    WRITE_CSR(stvec, (uintptr_t) supervisor_trap_entry);

    sv39_build_identity_map();
    __asm__ __volatile__("sfence.vma" ::: "memory");
    WRITE_CSR(satp, SATP_SV39 | ((uintptr_t) sv39_root_pt >> 12));
    __asm__ __volatile__("sfence.vma" ::: "memory");

    uint64_t value = sv39_test_word;
    if (value != 0x13579bdf2468ace0ULL)
        PANIC("Sv39 load identity failed value=%lx", value);

    sv39_test_word = 0x0badc0de12345678ULL;
    if (sv39_test_word != 0x0badc0de12345678ULL)
        PANIC("Sv39 store identity failed value=%lx", sv39_test_word);
    printf("Sv39 identity load/store OK\n");

    sv39_map_l1_superpage(SV39_SUPERPAGE_ALIAS, SV39_RAM_BASE, SV39_PTE_FLAGS);
    uint64_t superpage_base_value = *(volatile uint64_t *) SV39_RAM_BASE;
    uint64_t superpage_alias_value = *(volatile uint64_t *) SV39_SUPERPAGE_ALIAS;
    if (superpage_alias_value != superpage_base_value)
        PANIC("Sv39 L1 superpage failed value=%lx expected=%lx", superpage_alias_value, superpage_base_value);
    printf("Sv39 L1 superpage OK\n");

    sv39_map_l2_superpage(SV39_L2_SUPERPAGE_ALIAS, SV39_RAM_BASE, SV39_PTE_FLAGS);
    uint64_t l2_superpage_alias_value = *(volatile uint64_t *) SV39_L2_SUPERPAGE_ALIAS;
    if (l2_superpage_alias_value != superpage_base_value)
        PANIC("Sv39 L2 superpage failed value=%lx expected=%lx", l2_superpage_alias_value, superpage_base_value);
    printf("Sv39 L2 superpage OK\n");

    sv39_load_fault_seen = 0;
    __asm__ __volatile__("ld zero, 0(%0)" :: "r" (0x60000000UL) : "memory");
    if (!sv39_load_fault_seen)
        PANIC("Sv39 load page fault was not raised");
    printf("Sv39 load page fault OK\n");

    uintptr_t saved_sstatus = READ_CSR(sstatus);

    sv39_remap_page((uintptr_t) sv39_user_page, PAGE_V | PAGE_R | PAGE_W | PAGE_U | PAGE_A | PAGE_D);
    WRITE_CSR(sstatus, saved_sstatus & ~SSTATUS_SUM);
    sv39_sum_fault_seen = 0;
    __asm__ __volatile__("ld zero, 0(%0)" :: "r" (sv39_user_page) : "memory");
    if (!sv39_sum_fault_seen)
        PANIC("Sv39 SUM=0 fault was not raised");
    WRITE_CSR(sstatus, saved_sstatus | SSTATUS_SUM);
    value = sv39_user_page[0];
    if (value != 0x123456789abcdef0ULL)
        PANIC("Sv39 SUM=1 load failed value=%lx", value);
    WRITE_CSR(sstatus, saved_sstatus);
    printf("Sv39 SUM permission OK\n");

    sv39_remap_page((uintptr_t) sv39_exec_page, PAGE_V | PAGE_X | PAGE_A | PAGE_D);
    WRITE_CSR(sstatus, saved_sstatus & ~SSTATUS_MXR);
    sv39_mxr_fault_seen = 0;
    __asm__ __volatile__("ld zero, 0(%0)" :: "r" (sv39_exec_page) : "memory");
    if (!sv39_mxr_fault_seen)
        PANIC("Sv39 MXR=0 fault was not raised");
    WRITE_CSR(sstatus, saved_sstatus | SSTATUS_MXR);
    value = sv39_exec_page[0];
    if (value != 0xfeedfacecafebeefULL)
        PANIC("Sv39 MXR=1 load failed value=%lx", value);
    WRITE_CSR(sstatus, saved_sstatus);
    printf("Sv39 MXR permission OK\n");

    WRITE_CSR(satp, 0);
    __asm__ __volatile__("sfence.vma" ::: "memory");
#endif
}
