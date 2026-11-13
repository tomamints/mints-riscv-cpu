#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <string.h>
#include "../common/board_gpio.h"

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 ||
        (strcmp(argv[1],"status") && strcmp(argv[1],"leds") &&
         strcmp(argv[1],"diagnostics") && strcmp(argv[1],"self-test"))) {
        fputs("Usage: boardctl status | leds <0..1023> | diagnostics | self-test\n",stderr); return 2;
    }
    unsigned long leds = 0;
    if (!strcmp(argv[1],"leds")) {
        if (argc != 3) return 2;
        char *end; errno=0; leds=strtoul(argv[2],&end,0);
        if (errno || !*argv[2] || *end || leds>1023) {
            fputs("LED mask must be 0..1023 (decimal or hex)\n",stderr); return 2;
        }
    } else if (argc != 2) return 2;
    struct board_gpio gpio;
    if (gpio_open(&gpio)) return 1;
    int rc=0;
    if (!strcmp(argv[1],"leds")) gpio_control(&gpio,(uint16_t)(0x400|leds));
    else if (!strcmp(argv[1],"diagnostics")) gpio_control(&gpio,0);
    else if (!strcmp(argv[1],"self-test")) {
        uint64_t before=gpio_read(&gpio);
        const uint16_t patterns[]={0x555,0x6aa,0x400,0x7ff};
        for (unsigned i=0;i<sizeof patterns/sizeof patterns[0];++i) {
            gpio_control(&gpio,patterns[i]);
            uint64_t value=gpio_read(&gpio);
            if ((value&0x7ff)!=patterns[i] || (value>>48)!=(before>>48)) rc=1;
        }
        gpio_control(&gpio,gpio.saved);
        puts(rc ? "GPIO-SELFTEST-FAIL" : "GPIO-SELFTEST-PASS");
    }
    uint64_t value=gpio_read(&gpio);
    printf("GPIO: switches=0x%03" PRIx64 " pressed_keys=0x%01" PRIx64
           " leds=0x%03" PRIx64 " mode=%s\n",(value>>16)&0x3ff,(value>>32)&0xf,
           value&0x3ff,(value&0x400)?"application":"diagnostics");
    gpio_close(&gpio,0); return rc;
}
