#include "common.h"

void putchar(char ch);

void printf(const char *fmt, ...){  //printf("test %d", a);のように、, のあとは再現なく入れられるようにするため
    va_list vargs;
    va_start(vargs, fmt);

    while (*fmt){
        if(*fmt == '%'){
            fmt++;
            switch(*fmt){
                case '\0':
                    putchar('%');
                    goto end;
                case '%' :
                    putchar('%');
                    break;
                case 's' : { //文字列string
                    const char *s = va_arg(vargs, const char *);//chatの型で取り出す
                    while (*s) {
                        putchar(*s);
                        s++;
                    }
                    break;
                }
                case 'd' : { //dicimal
                    int value = va_arg(vargs, const int); //数字
                    unsigned magnitude;

                    if (value < 0){
                        putchar('-');
                        magnitude = (unsigned)(0u - (unsigned)value);
                    } else {
                        magnitude = (unsigned)value;
                    }

                    unsigned divisor = 1;
                    while (magnitude / divisor > 9)
                        divisor *= 10;

                    while (divisor > 0){
                        unsigned digit = magnitude / divisor;
                        putchar('0' + digit);
                        magnitude %= divisor;
                        divisor /= 10;
                    }

                    break;
                }
                case 'x' : {
                    unsigned value = va_arg(vargs, unsigned);
                    for (int i = 7; i>= 0; i--){
                        int nibble = (value >> (i * 4)) & 0xf;
                        putchar("0123456789abcdef"[nibble]);
                    }
                    break;
                }
            }
        } else {
            putchar(*fmt);
        }
        fmt++;
    }
end:
    va_end(vargs);
}

//bufの先頭からnバイト分をcで埋める
void *memset(void *buf, char c, size_t n){
    uint8_t *p = (uint8_t *) buf;
    while (n--)
        *p++ = c;
    return buf;
}

//srcからnバイト分をdstにコピー
void *memcpy(void *dst, const void *src, size_t n){
    uint8_t *d = (uint8_t *) dst;
    const uint8_t *s = (const uint8_t *) src;
    while(n--)
        *d++ = *s++;
    return dst;
}

char *strcpy(char *dst, const char *src, size_t size){
    char *d = dst;

    if(size == 0) return dst;

    while(*src && size > 1){
        *d++ = *src++;
        size--;
    }
     *d = '\0';
     return dst;
}

int strcmp(const char *s1, const char *s2){
    while(*s1 && *s2){
        if(*s1 != *s2)
            break;
        s1++;
        s2++;
    }

    return *(unsigned char *)s1 - *(unsigned char*)s2;
}

