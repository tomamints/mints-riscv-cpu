#pragma once
#include "common.h"

struct sbiret{
    long error;
    long value;
};

//マクロなので1行にするため「\」をつける
#define PANIC(fmt, ...) \
    do{                 \
        printf("PANIC: %s:%d:" fmt "\n", __FILE__, __LINE__, ##__VA_ARGS__); \
        while(1){} \
    } while(0)


struct trap_frame{
    uint64_t ra;
    uint64_t gp;
    uint64_t tp;
    uint64_t t0;
    uint64_t t1;
    uint64_t t2;
    uint64_t t3;
    uint64_t t4;
    uint64_t t5;
    uint64_t t6;
    uint64_t a0;
    uint64_t a1;
    uint64_t a2;
    uint64_t a3;
    uint64_t a4;
    uint64_t a5;
    uint64_t a6;
    uint64_t a7;
    uint64_t s0;
    uint64_t s1;
    uint64_t s2;
    uint64_t s3;
    uint64_t s4;
    uint64_t s5;
    uint64_t s6;
    uint64_t s7;
    uint64_t s8;
    uint64_t s9;
    uint64_t s10;
    uint64_t s11;
    uint64_t sp;
} __attribute__((packed));

void kernel_trap_entry(void);
void supervisor_trap_entry(void);
void kernel_trap_handler(struct trap_frame *f);
void supervisor_trap_handler(struct trap_frame *f);

void platform_putchar(char ch);
long platform_getchar(void);
void platform_test_success(void);
void platform_set_timer(uint64_t stime_value);
void platform_stop_timer(void);
void platform_set_stip(void);
void putchar(char ch);
long getchar(void);

struct sbiret sbi_call(long eid, long fid, long arg0);
void sbi_putchar(char ch);
long sbi_getchar(void);
struct sbiret sbi_set_timer(uint64_t stime_value);
struct sbiret sbi_test_read_pmp_word(void);
struct sbiret sbi_test_allow_exec_only_target(void);
struct sbiret sbi_test_protect_exec_target(void);
void firmware_handle_sbi(struct trap_frame *f);
void test_smode_basic(void);
void test_sbi_putchar(void);
void test_sbi_getchar(void);
void test_sbi_timer(void);
void test_smode_trap(void);
void test_pmp_data_fault(void);
void test_umode_transition(void);

extern volatile uint64_t pmp_protected_word;
extern volatile int pmp_load_fault_seen;
extern volatile int pmp_store_fault_seen;
extern volatile int pmp_exec_fault_seen;
void pmp_protected_exec_target(void);
extern volatile int umode_step;
extern volatile int umode_ecall_seen;

#define READ_CSR(reg)\
    ({\
        unsigned long __tmp;\
        __asm__ __volatile__("csrr %0, " #reg : "=r"(__tmp));\
        __tmp;\
    })


#define WRITE_CSR(reg, value)\
    do{\
        uint64_t __tmp = (uint64_t)(value);\
        __asm__ __volatile__("csrw " #reg ", %0" ::"r"(__tmp));\
    }while(0)


#define PROCS_MAX 8 //最大プロセス数

#define PROC_UNUSED 0 //未使用プロセス管理構造体
#define PROC_RUNNABLE 1 //executable process

struct process
{
    int pid;    //processId
    int state;  //process state PROC_UNUSED or RUNNABLE
    vaddr_t sp; //stack pointer
    uint64_t *page_table; // page table
    uint8_t stack[8192]; //kernel stack
};

//PTE
#define SATP_SV39 (8ULL << 60)
#define PAGE_V    (1ULL << 0) // Valid
#define PAGE_R    (1ULL << 1) // Readable
#define PAGE_W    (1ULL << 2) // Writable
#define PAGE_X    (1ULL << 3) // Executable
#define PAGE_U    (1ULL << 4) // User
#define PAGE_G    (1ULL << 5) // Global
#define PAGE_A    (1ULL << 6) // Accessed
#define PAGE_D    (1ULL << 7) // Dirty

//USER MODE
#define USER_BASE 0x1000000

//S MODE
#define SSTATUS_SPIE (1 << 5)
#define SSTATUS_SPP (1UL << 8)

#define SCAUSE_ECALL 8
#define MSTATUS_MIE (1UL << 3)
#define MIE_MTIE (1UL << 7)
#define MCOUNTEREN_TIME (1UL << 1)
#define MIDELEG_STI (1UL << 5)
#define PMP_R (1UL << 0)
#define PMP_W (1UL << 1)
#define PMP_X (1UL << 2)
#define PMP_A_TOR (1UL << 3)
#define PMP_A_NAPOT (3UL << 3)
#define SSTATUS_SIE (1UL << 1)
#define SIE_STIE (1UL << 5)
#define SIP_STIP (1UL << 5)
#define MCAUSE_INTERRUPT_BIT (1ULL << 63)
#define MCAUSE_MACHINE_TIMER_INTERRUPT (MCAUSE_INTERRUPT_BIT | 7ULL)
#define SCAUSE_SUPERVISOR_TIMER_INTERRUPT (MCAUSE_INTERRUPT_BIT | 5ULL)
#define MCAUSE_ECALL_FROM_U 8
#define MCAUSE_ECALL_FROM_S 9
#define MCAUSE_ECALL_FROM_M 11
#define INSTRUCTION_ACCESS_FAULT 1
#define LOAD_ACCESS_FAULT 5
#define STORE_AMO_ACCESS_FAULT 7

#define SBI_SUCCESS 0
#define SBI_ERR_NOT_SUPPORTED -2

#define SBI_EXT_TIME 0x54494d45UL
#define SBI_FUNC_TIME_SET_TIMER 0

#define SBI_EXT_DEBUG_CONSOLE 0x4442434eUL
#define SBI_FUNC_DEBUG_CONSOLE_PUTCHAR 0
#define SBI_FUNC_DEBUG_CONSOLE_GETCHAR 1

#define SBI_EXT_TEST 0x54534554UL
#define SBI_FUNC_TEST_READ_PMP_WORD 0
#define SBI_FUNC_TEST_ALLOW_EXEC_ONLY_TARGET 1
#define SBI_FUNC_TEST_PROTECT_EXEC_TARGET 2

#define PROC_EXITED 2


//vertIO

#define SECTOR_SIZE       512
#define VIRTQ_ENTRY_NUM   16
#define VIRTIO_DEVICE_BLK 2
#define VIRTIO_BLK_PADDR  0x10001000
#define VIRTIO_REG_MAGIC         0x00
#define VIRTIO_REG_VERSION       0x04
#define VIRTIO_REG_DEVICE_ID     0x08
#define VIRTIO_REG_PAGE_SIZE     0x28
#define VIRTIO_REG_QUEUE_SEL     0x30
#define VIRTIO_REG_QUEUE_NUM_MAX 0x34
#define VIRTIO_REG_QUEUE_NUM     0x38
#define VIRTIO_REG_QUEUE_PFN     0x40
#define VIRTIO_REG_QUEUE_READY   0x44
#define VIRTIO_REG_QUEUE_NOTIFY  0x50
#define VIRTIO_REG_DEVICE_STATUS 0x70
#define VIRTIO_REG_DEVICE_CONFIG 0x100
#define VIRTIO_STATUS_ACK       1
#define VIRTIO_STATUS_DRIVER    2
#define VIRTIO_STATUS_DRIVER_OK 4
#define VIRTQ_DESC_F_NEXT          1
#define VIRTQ_DESC_F_WRITE         2
#define VIRTQ_AVAIL_F_NO_INTERRUPT 1
#define VIRTIO_BLK_T_IN  0
#define VIRTIO_BLK_T_OUT 1

struct virtq_desc {
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct virtq_avail {
    uint16_t flags;
    uint16_t index;
    uint16_t ring[VIRTQ_ENTRY_NUM];
} __attribute__((packed));

struct virtq_used_elem {
    uint32_t id;
    uint32_t len;
} __attribute__((packed));

struct virtq_used {
    uint16_t flags;
    uint16_t index;
    struct virtq_used_elem ring[VIRTQ_ENTRY_NUM];
} __attribute__((packed));

struct virtio_virtq {
    struct virtq_desc descs[VIRTQ_ENTRY_NUM];
    struct virtq_avail avail;
    struct virtq_used used __attribute__((aligned(PAGE_SIZE)));
    int queue_index;
    volatile uint16_t *used_index;
    uint16_t last_used_index;
} __attribute__((packed));


struct virtio_blk_req {
    // 1つ目のディスクリプタ: デバイスからは読み込み専用
    uint32_t type;
    uint32_t reserved;
    uint64_t sector;

    // 2つ目のディスクリプタ: 読み込み処理の場合は、デバイスから書き込み可 (VIRTQ_DESC_F_WRITE)
    uint8_t data[512];

    // 3つ目のディスクリプタ: デバイスから書き込み可 (VIRTQ_DESC_F_WRITE)
    uint8_t status;
} __attribute__((packed));
