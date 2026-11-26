#ifndef MINTS_RVMODEL_MACROS_H
#define MINTS_RVMODEL_MACROS_H

#define STANDARD_SM_SUPPORTED
#define RVMODEL_DATA_SECTION \
  .pushsection .tohost,"aw",@progbits; \
  .balign 8; .global tohost; tohost: .dword 0; \
  .balign 8; .global fromhost; fromhost: .dword 0; \
  .popsection
#define RVMODEL_BOOT
#define MINTS_TEST_RESULT(value) \
  li t1, value; la t0, tohost; \
1: sw t1, 0(t0); j 1b
#define RVMODEL_HALT_PASS MINTS_TEST_RESULT(1)
#define RVMODEL_HALT_FAIL MINTS_TEST_RESULT(3)
#define RVMODEL_IO_INIT(r1, r2, r3)
#define RVMODEL_IO_WRITE_STR(r1, r2, r3, ptr)

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x18000000
#define RVMODEL_MTIME_ADDRESS 0x0200bff8
#define RVMODEL_MTIMECMP_ADDRESS 0x02004000
#define RVMODEL_TIMER_INT_SOON_DELAY 5000
#define RVMODEL_INTERRUPT_LATENCY 64

#define RVMODEL_SET_MSW_INT(r1, r2) \
  li r1, 1; li r2, 0x02000000; sw r1, 0(r2)
#define RVMODEL_CLR_MSW_INT(r1, r2) \
  li r2, 0x02000000; sw zero, 0(r2)

#endif
