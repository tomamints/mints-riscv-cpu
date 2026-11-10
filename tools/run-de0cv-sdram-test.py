#!/usr/bin/env python3
"""Poll the read-only SDRAM virtual JTAG status until stable PASS or FAIL."""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import time

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout',type=float,
                        help='seconds (default: 300 at 20MHz, otherwise 180)')
    parser.add_argument('--accept-existing', action='store_true',
                        help='allow a PASS already latched before polling starts')
    args=parser.parse_args()
    root=Path(__file__).resolve().parent.parent
    profile_clock=50_000_000
    config=root/'build/fpga/de0-cv-sdram-test/build-config.txt'
    if config.exists():
        for line in config.read_text().splitlines():
            key,separator,value=line.partition('=')
            if key=='SDRAM_CLK_HZ' and separator:
                profile_clock=int(value)
    if profile_clock not in (20_000_000,50_000_000):
        parser.error('unsupported built SDRAM clock profile')
    timeout=args.timeout if args.timeout is not None else (300 if profile_clock==20_000_000 else 180)
    if timeout<=0:
        parser.error('--timeout must be positive')
    reader=root/'local/fpga-tools/bin/de0cv-jtag-status'
    logdir=root/'build/logs'
    logdir.mkdir(parents=True,exist_ok=True)
    path=logdir/('sdram-jtag-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'.log')
    with path.open('w') as log:
        def emit(text):
            print(text,flush=True)
            log.write(text+'\n'); log.flush()
        def read(register=0):
            proc=subprocess.run([str(reader),str(register)],capture_output=True,text=True,timeout=15)
            if proc.returncode:
                raise RuntimeError(proc.stderr.strip() or proc.stdout.strip())
            return int(json.loads(proc.stdout.strip().splitlines()[-1])['status'],16)
        emit(f'profile_clock={profile_clock} timeout={timeout}s')
        deadline=time.monotonic()+timeout
        stable=0
        observed_running=False
        errors=0
        last=None
        while time.monotonic()<deadline:
            try:
                value=read()
                errors=0
            except (RuntimeError,ValueError,KeyError,OSError,subprocess.TimeoutExpired) as exc:
                errors+=1; emit(f'JTAG read error {errors}: {exc}')
                if errors>=3: return 2
                time.sleep(1); continue
            if value!=last: emit(f'status=0x{value:08x}'); last=value
            if value & 2:
                try:
                    diagnostics=[read(i) for i in (1,2,3)]
                except (RuntimeError,ValueError,KeyError,OSError,subprocess.TimeoutExpired) as exc:
                    emit(f'SDRAM-TEST-FAIL (diagnostic read failed: {exc})'); return 2
                emit('SDRAM-TEST-FAIL address=0x%08x expected_low=0x%08x actual_low=0x%08x'%tuple(diagnostics))
                return 1
            if value & 1 and value & 4:
                if not observed_running and not args.accept_existing:
                    emit('SDRAM-TEST-STALE: PASS was already latched; reprogram or restart before polling')
                    return 2
                stable+=1
                if stable>=3:
                    emit('SDRAM-TEST-PASS (stable JTAG status)'); return 0
            else:
                stable=0
                observed_running=True
            time.sleep(1)
        emit('SDRAM-TEST-TIMEOUT'); return 1

if __name__=='__main__':
    raise SystemExit(main())
