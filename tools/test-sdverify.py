#!/usr/bin/env python3
"""Independent file-pattern reference and failure tests; no SD card needed."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parent.parent
out=root/'build/test/sdverify';out.mkdir(parents=True,exist_ok=True)
exe=out/'sdverify'
subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror',str(root/'examples/sdcheck/sdverify.c'),'-o',str(exe)],check=True)
def run(mode,path,ok=True):
 r=subprocess.run([str(exe),mode,str(path)],capture_output=True,text=True)
 assert (r.returncode==0)==ok,(r.returncode,r.stdout,r.stderr)
 return r.stdout
with tempfile.TemporaryDirectory(dir=out) as name:
 path=Path(name)/'verify.bin'
 run('create',path)
 expected=bytearray()
 for i in range(65536):
  v=(i*1315423911+(i>>7)*2654435761)&0xffffffff
  expected.append((v^(v>>11)^(v>>23)^0xa5)&255)
 assert path.read_bytes()==expected
 run('create',path,False);assert path.read_bytes()==expected,'existing data changed'
 run('verify',path)
 data=bytearray(expected);data[32768]^=1;path.write_bytes(data);run('verify',path,False)
 path.write_bytes(expected[:-1]);run('verify',path,False)
 path.write_bytes(expected+b'x');run('verify',path,False)
 path.write_bytes(expected)
 alias=Path(name)/'link';alias.symlink_to(path);run('create',alias,False);run('verify',alias,False)
 assert path.read_bytes()==expected
print('SDVERIFY_PASS: independent pattern, no overwrite, corruption/truncation/extra bytes/symlink rejection')
