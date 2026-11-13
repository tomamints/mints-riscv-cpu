#!/usr/bin/env python3
from pathlib import Path
import os,shlex,subprocess,tempfile
root=Path(__file__).resolve().parent.parent
out=root/'build/test/vga';out.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='mints-vga-client-') as directory:
    binary=str(Path(directory)/'client')
    subprocess.run(shlex.split(os.environ.get('CC','cc'))+['-std=c11','-O2','-Wall','-Wextra','-Werror',str(root/'tb/unit/test_vga_client.c'),'-o',binary],check=True)
    subprocess.run([binary,str(out/'life-screen.txt')],check=True)
text=(out/'life-screen.txt').read_bytes();assert len(text)==2400
state=0x4d494e54
for y in range(16):
    for x in range(32):
        state^=(state<<13)&0xffffffff;state^=state>>17;state^=(state<<5)&0xffffffff
        expected=ord('#') if state&3==0 else ord(' ')
        assert text[(y+5)*80+x+24]==expected,(x,y)
assert text[80+27:80+27+22]==b'MINTS CPU / LINUX LIFE'
print('VGA CLIENT LAYOUT PASS: all seeded cells match independent model')
