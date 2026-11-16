#!/usr/bin/env python3
"""Exercise Linux GPIO clients with a file-backed register, without FPGA access."""
import mmap
import os
from pathlib import Path
import re
import shlex
import signal
import struct
import subprocess
import tempfile
import time

root=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='mints-gpio-') as directory:
    out=Path(directory)
    binaries={}
    for name in ('life','boardctl'):
        binary=out/name
        subprocess.run(shlex.split(os.environ.get('CC','cc'))+
                       ['-std=c11','-O2','-Wall','-Wextra','-Werror',
                        str(root/f'examples/{name}/{name}.c'),'-o',str(binary)],check=True)
        binaries[name]=str(binary)
    backing=out/'register'
    backing.write_bytes(bytes(4096))
    env={**os.environ,'MINTS_GPIO_DEVICE':str(backing)}
    def run(name,*args,ok=0):
        result=subprocess.run([binaries[name],*args],env=env,text=True,capture_output=True,timeout=5)
        assert result.returncode==ok,(args,result.stdout,result.stderr)
        return result.stdout
    with backing.open('r+b') as file, mmap.mmap(file.fileno(),4096) as reg:
        def value():return struct.unpack_from('<Q',reg)[0]
        struct.pack_into('<Q',reg,0,(0x4d47<<48)|(0xa<<32)|(0x2a4<<16)|0x123)
        assert 'switches=0x2a4 pressed_keys=0xa' in run('boardctl','status')
        run('boardctl','leds','0x155');assert value()&0x7ff==0x555
        run('boardctl','diagnostics');assert value()&0x7ff==0
        assert 'GPIO-SELFTEST-PASS' in run('boardctl','self-test')
        assert value()&0x7ff==0 and value()>>32==(0x4d47<<16)|0xa
        run('boardctl','leds','1024',ok=2)
        run('boardctl','leds','bad',ok=2)
        # Running board mode computes the same world as the ordinary benchmark.
        reg[4]=0
        board=run('life','--board','2')
        bench=run('life','--bench','2')
        assert re.search(r'Checksum: (\w+)',board)[1]==re.search(r'Checksum: (\w+)',bench)[1]
        assert value()&0x7ff==0
        # Pause, resume, debounced reset while paused, and signal cleanup.
        struct.pack_into('<H',reg,0,0x512)
        struct.pack_into('<H',reg,2,1)
        capture=out/'capture'
        with capture.open('w') as log:
            process=subprocess.Popen([binaries['life'],'--board','100'],env=env,stdout=log,stderr=log)
            def wait_for(predicate):
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    if predicate(capture.read_text()):return
                    if process.poll() is not None:raise AssertionError(capture.read_text())
                    time.sleep(.01)
                raise AssertionError(capture.read_text())
            try:
                wait_for(lambda text:'PAUSED' in text)
                assert 'generation 1 ' not in capture.read_text()
                struct.pack_into('<H',reg,2,0)
                wait_for(lambda text:'generation 2 ' in text)
                struct.pack_into('<H',reg,2,1)
                wait_for(lambda text:text.count('PAUSED')>=2)
                reg[4]=1
                wait_for(lambda text:text.count('generation 0 ')>=2)
                process.send_signal(signal.SIGINT)
                assert process.wait(timeout=5)==0
            finally:
                if process.poll() is None:process.kill();process.wait()
        assert value()&0x7ff==0x512,'previous LED ownership not restored'
        # Wrong FPGA/register ID must be rejected before any control write.
        reg[6:8]=b'\0\0';before=reg[:]
        run('boardctl','leds','1',ok=1)
        assert reg[:]==before
print('BOARD APPS PASS: status/control, ID guard, deterministic Life, pause/resume/reset and SIGINT restoration')
