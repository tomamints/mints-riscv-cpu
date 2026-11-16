#!/usr/bin/env python3
"""Check a simulated VGA frame against an independent text/font pixel model."""
from pathlib import Path
import struct,zlib
root=Path(__file__).resolve().parent.parent
raw=(root/'build/test/vga/frame.ppm').read_bytes()
header=b'P6\n640 480\n255\n';assert raw.startswith(header)
pixels=raw[len(header):];assert len(pixels)==640*480*3
font=[int(x,16) for x in (root/'fpga/de0-cv/vga/font8x8.hex').read_text().split()]
text=[ord(' ')]*2400
for i,c in enumerate('MINTS'):text[84+i]=ord(c)
text[80*4+20]=ord('#')
expected=bytearray()
for y in range(480):
    for x in range(640):
        c=text[(y//16)*80+x//8]
        on=(font[(c&127)*8+(y%16)//2]>>(7-x%8))&1
        expected.extend((0,255,0) if on and c==ord('#') else (255,255,255) if on else (0,0,0))
assert pixels==expected,'VGA font/pixel pipeline differs from reference'
def chunk(kind,data):
    return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
scan=b''.join(b'\0'+pixels[y*640*3:(y+1)*640*3] for y in range(480))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',640,480,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b'')
(root/'build/test/vga/frame.png').write_bytes(png)
print('VGA FRAME PASS: all 307,200 visible pixels match independent model')
