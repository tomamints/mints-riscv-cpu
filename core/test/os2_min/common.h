#pragma once

#define va_list __builtin_va_list
#define va_start __builtin_va_start
#define va_end __builtin_va_end
#define va_arg __builtin_va_arg

typedef int bool;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef long long int64_t;
typedef unsigned long size_t;
typedef uint64_t uintptr_t;
typedef uint64_t paddr_t; // physical address
typedef uint64_t vaddr_t; // virtual address

#define true  1
#define false 0
#define NULL  ((void *) 0)
#define align_up(value, align)   (((value) + (align) - 1) & ~((align) - 1))
#define is_aligned(value, align) (((value) & ((align) - 1)) == 0)
#define offsetof(type, member)   __builtin_offsetof(type, member) //構造体のメンバのオフセットを返す

void *memset(void *buf, char c, size_t n);
void *memcpy(void *dst, const void *src, size_t n);
char *strcpy(char *dst, const char *src, size_t size);
int strcmp(const char *s1, const char *s2);
void printf(const char *fmt, ...);

#define PAGE_SIZE 4096
