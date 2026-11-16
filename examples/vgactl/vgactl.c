#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include "../common/vga_text.h"
int main(int argc,char **argv) {
    if(argc!=2 || (strcmp(argv[1],"status") && strcmp(argv[1],"demo") && strcmp(argv[1],"self-test"))) {
        fputs("Usage: vgactl status | demo | self-test\n",stderr);return 2;
    }
    struct board_gpio gpio;if(gpio_open(&gpio))return 1;
    if(vga_check(&gpio)) { gpio_close(&gpio,0);return 1; }
    int rc=0;
    if(strcmp(argv[1],"status")) {
        char screen[VGA_CELLS];memset(screen,' ',sizeof screen);
        vga_line(screen,3,22,"MINTS CPU / LINUX VGA");
        vga_line(screen,6,18,"RV64IMAC / 20 MHZ / 64 MIB SDRAM");
        vga_line(screen,9,16,"THIS SCREEN WAS WRITTEN BY A LINUX C PROGRAM");
        vga_line(screen,13,22,"TYPE LIFE --VGA 40 ON UART");
        vga_line(screen,17,22,"0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ");
        if(!strcmp(argv[1],"self-test")) {
            memset(screen,'#',sizeof screen);
            if(vga_show(&gpio,screen))rc=1;
            memset(screen,' ',sizeof screen);vga_line(screen,4,20,"MINTS VGA SELFTEST");
        }
        if(!rc && vga_show(&gpio,screen))rc=1;
        if(!strcmp(argv[1],"self-test"))puts(rc?"VGA-SELFTEST-FAIL":"VGA-SELFTEST-PASS");
    }
    uint64_t state=vga_status(&gpio);
    printf("VGA: presented=%" PRIu32 " busy=%u\n",(uint32_t)state,(unsigned)((state>>32)&1));
    gpio_close(&gpio,0);return rc;
}
