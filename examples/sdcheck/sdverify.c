#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TOTAL 65536u
static unsigned char pattern(unsigned i) {
    uint32_t v=(uint32_t)i*UINT32_C(1315423911)+(i>>7)*UINT32_C(2654435761);
    return (unsigned char)(v^(v>>11)^(v>>23)^0xa5);
}
static int failed(const char *what,int fd) {
    perror(what);if(fd>=0)close(fd);return 1;
}
int main(int argc,char **argv) {
    if(argc!=3 || (strcmp(argv[1],"create") && strcmp(argv[1],"verify"))) {
        fputs("Usage: sdverify create|verify <file>\ncreate refuses existing paths; verify reads only\n",stderr);return 2;
    }
    int create=!strcmp(argv[1],"create");
    int fd=open(argv[2],(create?(O_WRONLY|O_CREAT|O_EXCL):O_RDONLY)|O_NOFOLLOW,0600);
    if(fd<0)return failed("open",-1);
    unsigned char buffer[512];uint64_t hash=UINT64_C(14695981039346656037);
    for(unsigned off=0;off<TOTAL;off+=sizeof buffer) {
        if(create)for(unsigned j=0;j<sizeof buffer;j++)buffer[j]=pattern(off+j);
        size_t done=0;
        while(done<sizeof buffer) {
            ssize_t n=create?write(fd,buffer+done,sizeof buffer-done):read(fd,buffer+done,sizeof buffer-done);
            if(n<0 && errno==EINTR)continue;
            if(n<0)return failed(create?"write":"read",fd);
            if(n==0){fputs("SD-VERIFY-FAIL: short file/transfer\n",stderr);close(fd);return 1;}
            done+=(size_t)n;
        }
        for(unsigned j=0;j<sizeof buffer;j++) {
            if(!create && buffer[j]!=pattern(off+j)) {
                fprintf(stderr,"SD-VERIFY-FAIL: byte %u\n",off+j);close(fd);return 1;
            }
            hash=(hash^buffer[j])*UINT64_C(1099511628211);
        }
    }
    if(create) {
        if(fsync(fd))return failed("fsync file",fd);
    } else {
        unsigned char extra;ssize_t n;
        do n=read(fd,&extra,1);while(n<0 && errno==EINTR);
        if(n<0)return failed("read end",fd);
        if(n!=0){fputs("SD-VERIFY-FAIL: extra data\n",stderr);close(fd);return 1;}
    }
    if(close(fd))return failed("close",-1);
    if(create) {
        char *parent=strdup(argv[2]);if(!parent)return failed("strdup",-1);
        char *slash=strrchr(parent,'/');
        if(slash){if(slash==parent)slash[1]=0;else *slash=0;}
        else {free(parent);parent=strdup(".");if(!parent)return failed("strdup",-1);}
        int dir=open(parent,O_RDONLY|O_DIRECTORY);free(parent);
        if(dir<0)return failed("open parent",-1);
        if(fsync(dir))return failed("fsync parent",dir);
        if(close(dir))return failed("close parent",-1);
    }
    printf("SD-%s-PASS: bytes=%u checksum=%016" PRIx64 "\n",create?"CREATE":"VERIFY",TOTAL,hash);
    return 0;
}
