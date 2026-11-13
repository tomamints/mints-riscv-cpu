#ifndef MINTS_VGA_TEXT_H
#define MINTS_VGA_TEXT_H
#include <time.h>
#include <string.h>
#include "board_gpio.h"
enum { VGA_COLUMNS=80,VGA_ROWS=30,VGA_CELLS=2400 };
#ifdef MINTS_VGA_TEST
uint64_t mints_vga_test_status(void);
void mints_vga_test_command(uint64_t value);
#endif
static inline uint64_t vga_status(struct board_gpio *gpio) {
    gpio_barrier();
#ifdef MINTS_VGA_TEST
    (void)gpio;uint64_t value=mints_vga_test_status();
#else
    uint64_t value=*(volatile uint64_t *)((char *)gpio->map+16);
#endif
    gpio_barrier();return value;
}
static inline int vga_check(struct board_gpio *gpio) {
    if (!(gpio_read(gpio)&(UINT64_C(1)<<47))) {
        fputs("This FPGA image has no VGA text interface\n",stderr);return -1;
    }
    if ((vga_status(gpio)>>48)!=UINT64_C(0x5654)) {
        fputs("VGA ID mismatch\n",stderr);return -1;
    }
    return 0;
}
static inline void vga_line(char *screen,unsigned row,unsigned col,const char *text) {
    if(row>=VGA_ROWS)return;
    while(*text && col<VGA_COLUMNS)screen[row*VGA_COLUMNS+col++]=*text++;
}
static inline void vga_command(struct board_gpio *gpio,uint64_t value) {
    gpio_barrier();
#ifdef MINTS_VGA_TEST
    (void)gpio;mints_vga_test_command(value);
#else
    *(volatile uint64_t *)((char *)gpio->map+8)=value;
#endif
    gpio_barrier();
}
static inline int vga_wait(struct board_gpio *gpio,uint32_t previous,int advance) {
    struct timespec start,now;
    if(clock_gettime(CLOCK_MONOTONIC,&start))return -1;
    for(;;) {
        uint64_t state=vga_status(gpio);
        if (!(state&(UINT64_C(1)<<32)) && (!advance || (uint32_t)state!=previous))return 0;
        if(clock_gettime(CLOCK_MONOTONIC,&now))return -1;
        int64_t elapsed=(int64_t)(now.tv_sec-start.tv_sec)*INT64_C(1000000000)+now.tv_nsec-start.tv_nsec;
        if(elapsed>INT64_C(2000000000)) { fputs("VGA present acknowledgement timed out\n",stderr);return -1; }
        struct timespec delay={0,1000000};nanosleep(&delay,NULL);
    }
}
static inline int vga_show(struct board_gpio *gpio,const char *screen) {
    if(vga_wait(gpio,0,0))return -1;
    uint32_t previous=(uint32_t)vga_status(gpio);
    for(unsigned i=0;i<VGA_CELLS;++i)
        vga_command(gpio,(uint64_t)i|((uint64_t)(unsigned char)screen[i]<<16));
    vga_command(gpio,UINT64_C(1)<<63);
    return vga_wait(gpio,previous,1);
}
#endif
