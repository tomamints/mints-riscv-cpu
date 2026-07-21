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
    uint32_t ra;
    uint32_t gp;
    uint32_t tp;
    uint32_t t0;
    uint32_t t1;
    uint32_t t2;
    uint32_t t3;
    uint32_t t4;
    uint32_t t5;
    uint32_t t6;
    uint32_t a0;
    uint32_t a1;
    uint32_t a2;
    uint32_t a3;
    uint32_t a4;
    uint32_t a5;
    uint32_t a6;
    uint32_t a7;
    uint32_t s0;
    uint32_t s1;
    uint32_t s2;
    uint32_t s3;
    uint32_t s4;
    uint32_t s5;
    uint32_t s6;
    uint32_t s7;
    uint32_t s8;
    uint32_t s9;
    uint32_t s10;
    uint32_t s11;
    uint32_t sp;
} __attribute__((packed));

#define READ_CSR(reg)\
    ({\
        unsigned long __tmp;\
        __asm__ __volatile__("csrr %0, " #reg : "=r"(__tmp));\
        __tmp;\
    })


#define WRITE_CSR(reg, value)\
    do{\
        uint32_t __tmp = (value);\
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
    uint32_t *page_table; //page table
    uint8_t stack[8192]; //kernel stack
};

//PTE
#define SATP_SV32 (1u << 31) //SV32モード
#define PAGE_V    (1 << 0) //有効ビット
#define PAGE_R    (1 << 1) //Readable
#define PAGE_W    (1 << 2) //Writable
#define PAGE_X    (1 << 3) //Executable
#define PAGE_U    (1 << 4) //User

//USER MODE
#define USER_BASE 0x1000000

//S MODE
#define SSTATUS_SPIE (1 << 5)

#define SCAUSE_ECALL 8

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
