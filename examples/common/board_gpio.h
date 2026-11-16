#ifndef MINTS_BOARD_GPIO_H
#define MINTS_BOARD_GPIO_H
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

struct board_gpio { void *map; uint16_t saved; };
static inline void gpio_barrier(void) { __sync_synchronize(); }
static inline uint64_t gpio_read(struct board_gpio *gpio) {
    gpio_barrier();
    uint64_t value = *(volatile uint64_t *)gpio->map;
    gpio_barrier(); return value;
}
static inline void gpio_control(struct board_gpio *gpio, uint16_t value) {
    gpio_barrier();
    *(volatile uint16_t *)gpio->map = value & UINT16_C(0x7ff);
    gpio_barrier();
}
static inline int gpio_open(struct board_gpio *gpio) {
    const char *path = getenv("MINTS_GPIO_DEVICE");
    if (!path || !*path) path = "/dev/uio0";
    gpio->map = MAP_FAILED;
    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) { perror(path); return -1; }
    gpio->map = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int error = errno; close(fd); errno = error;
    if (gpio->map == MAP_FAILED) { perror("GPIO mmap"); return -1; }
    if ((gpio_read(gpio) >> 48) != UINT64_C(0x4d47)) {
        fputs("GPIO ID mismatch; no registers were written\n", stderr);
        munmap(gpio->map,4096); gpio->map=MAP_FAILED; return -1;
    }
    gpio->saved = (uint16_t)(gpio_read(gpio) & 0x7ff);
    return 0;
}
static inline void gpio_close(struct board_gpio *gpio, int restore) {
    if (gpio->map == MAP_FAILED) return;
    if (restore) gpio_control(gpio, gpio->saved);
    munmap(gpio->map,4096); gpio->map=MAP_FAILED;
}
#endif
