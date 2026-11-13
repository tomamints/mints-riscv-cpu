#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Conway B3/S23, 32 x 16 torus. Padded borders avoid division per cell. */
enum { W = 32, H = 16, STRIDE = W + 2, SIZE = (W + 2) * (H + 2) };
static unsigned char grids[2][SIZE];
static unsigned char *current = grids[0], *next = grids[1];

static void clear_grid(void) {
    memset(grids, 0, sizeof grids);
    current = grids[0]; next = grids[1];
}
static void seed_grid(void) {
    uint32_t s = UINT32_C(0x4d494e54);
    clear_grid();
    for (unsigned y = 1; y <= H; ++y)
        for (unsigned x = 1; x <= W; ++x) {
            s ^= s << 13; s ^= s >> 17; s ^= s << 5;
            current[y * STRIDE + x] = (s & 3) == 0;
        }
}
static void step(void) {
    for (unsigned y = 1; y <= H; ++y) {
        current[y * STRIDE] = current[y * STRIDE + W];
        current[y * STRIDE + W + 1] = current[y * STRIDE + 1];
    }
    memcpy(current, current + H * STRIDE, STRIDE);
    memcpy(current + (H + 1) * STRIDE, current + STRIDE, STRIDE);
    for (unsigned y = 1; y <= H; ++y)
        for (unsigned x = 1; x <= W; ++x) {
            unsigned i = y * STRIDE + x;
            unsigned n = current[i - STRIDE - 1] + current[i - STRIDE] +
                current[i - STRIDE + 1] + current[i - 1] + current[i + 1] +
                current[i + STRIDE - 1] + current[i + STRIDE] + current[i + STRIDE + 1];
            next[i] = n == 3 || (current[i] && n == 2);
        }
    unsigned char *tmp = current; current = next; next = tmp;
}
static uint64_t checksum(void) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (unsigned y = 1; y <= H; ++y)
        for (unsigned x = 1; x <= W; ++x) {
            hash ^= current[y * STRIDE + x];
            hash *= UINT64_C(1099511628211);
        }
    return hash;
}
static int self_test(void) {
    clear_grid();
    current[2 * STRIDE + 2] = current[2 * STRIDE + 3] = 1;
    current[3 * STRIDE + 2] = current[3 * STRIDE + 3] = 1;
    uint64_t block = checksum(); step();
    if (checksum() != block) return 1;
    /* Blinker crossing the horizontal wrap boundary. */
    clear_grid(); current[5 * STRIDE + W] = current[5 * STRIDE + 1] = current[5 * STRIDE + 2] = 1;
    uint64_t blinker = checksum(); step();
    if (!current[4 * STRIDE + 1] || !current[5 * STRIDE + 1] || !current[6 * STRIDE + 1]) return 1;
    step(); if (checksum() != blinker) return 1;
    puts("LIFE-SELFTEST-PASS"); return 0;
}
static uint64_t ns(const struct timespec *t) {
    return (uint64_t)t->tv_sec * UINT64_C(1000000000) + (uint64_t)t->tv_nsec;
}
static void display(unsigned long gen, int ansi) {
    if (ansi) fputs("\033[H", stdout);
    printf("MiNTs Life | generation %lu | %dx%d torus\n", gen, W, H);
    for (unsigned y = 1; y <= H; ++y) {
        putchar('|');
        for (unsigned x = 1; x <= W; ++x) putchar(current[y * STRIDE + x] ? '#' : ' ');
        puts("|");
    }
    fflush(stdout);
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--self-test")) return self_test();
    int demo = argc >= 2 && !strcmp(argv[1], "--demo");
    if (argc < 2 || argc > 3 || (!demo && strcmp(argv[1], "--bench"))) {
        fprintf(stderr, "Usage: life --demo [generations] | --bench [generations] | --self-test\n");
        return 2;
    }
    unsigned long count = demo ? 40 : 100;
    if (argc == 3) {
        char *end; errno = 0; count = strtoul(argv[2], &end, 10);
        if (errno || !*argv[2] || *end || argv[2][0] == '-' || !count || count > 1000000) {
            fputs("generations must be 1..1000000\n", stderr); return 2;
        }
    }
    seed_grid();
    if (demo) {
        int ansi = isatty(STDOUT_FILENO);
        if (ansi) fputs("\033[2J", stdout);
        display(0, ansi);
        for (unsigned long g = 1; g <= count; ++g) {
            step(); display(g, ansi);
            struct timespec delay = {0, 200000000};
            while (nanosleep(&delay, &delay) && errno == EINTR) {}
        }
    } else {
        struct timespec start, end;
        printf("MiNTs Life benchmark: %dx%d, %lu generations, fixed seed 0x4d494e54\n", W, H, count);
        fflush(stdout);
        if (clock_gettime(CLOCK_MONOTONIC, &start)) { perror("clock_gettime"); return 1; }
        for (unsigned long g = 0; g < count; ++g) step();
        if (clock_gettime(CLOCK_MONOTONIC, &end)) { perror("clock_gettime"); return 1; }
        uint64_t elapsed = ns(&end) - ns(&start), updates = (uint64_t)W * H * count;
        printf("Elapsed: %" PRIu64 ".%09" PRIu64 " s\n", elapsed / 1000000000, elapsed % 1000000000);
        printf("Cell updates: %" PRIu64 "\n", updates);
        if (elapsed) printf("Cell updates/s: %" PRIu64 "\n", updates * UINT64_C(1000000000) / elapsed);
    }
    printf("Checksum: %016" PRIx64 "\n", checksum());
    return 0;
}
