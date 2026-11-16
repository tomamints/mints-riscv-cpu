#define _POSIX_C_SOURCE 200809L
#define MINTS_VGA_TEST
#define main life_main_unused
#include "../../examples/life/life.c"
#undef main
#include <assert.h>
static char pages[2][4096];
static unsigned front=0,back=1,busy_mock=1,polls=0,count_mock=1,writes=0,status_calls=0;
uint64_t mints_vga_test_status(void) {
    ++status_calls;
    if(busy_mock && ++polls==3) { front^=1;back^=1;busy_mock=0;++count_mock; }
    return (UINT64_C(0x5654)<<48)|((uint64_t)busy_mock<<32)|count_mock;
}
void mints_vga_test_command(uint64_t value) {
    assert(!busy_mock);
    if(value>>63) { assert(value==(UINT64_C(1)<<63));busy_mock=1;polls=0; }
    else { assert((value&4095)<2400);pages[back][value&4095]=(char)(value>>16);++writes; }
}
int main(int argc,char **argv) {
    assert(argc==2);
    uint64_t reg[4]={(UINT64_C(0x4d47)<<48)};
    struct board_gpio gpio={.map=reg,.saved=0};
    assert(vga_check(&gpio)==-1 && status_calls==0); // Old FPGA must not read offset 16.
    reg[0]|=UINT64_C(1)<<47;assert(vga_check(&gpio)==0);
    seed_grid();assert(video_display(&gpio,0,0)==0);
    assert(count_mock==3 && !busy_mock && writes==2400); // Waits out a previous swap first.
    FILE *file=fopen(argv[1],"wb");assert(file);
    assert(fwrite(pages[front],1,2400,file)==2400);fclose(file);
    char screen[2400];memset(screen,' ',sizeof screen);
    vga_line(screen,29,78,"ABCD");assert(screen[2398]=='A' && screen[2399]=='B');
    vga_line(screen,30,0,"BAD");
    puts("VGA_CLIENT_PASS: feature guard, pending swap, command stream and Life framebuffer");
}
