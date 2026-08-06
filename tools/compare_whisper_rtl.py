#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from pathlib import Path
from typing import Iterable, Optional

WHISPER_RE = re.compile(r'^#(?P<order>\d+)\s+(?P<hart>\d+)\s+(?P<priv>[A-Za-z]+)\s+(?P<pc>[0-9a-fA-F]+)\s+(?P<inst>[0-9a-fA-F]+)\s+(?P<kind>[rm])\s+(?P<arg1>[0-9a-fA-F]+)\s+(?P<arg2>[0-9a-fA-F]+)\s+(?P<disasm>.*)$')
RTL_RE = re.compile(r'^\[RETIRE\]\s+order=(?P<order>\d+)\s+pc=(?P<pc>[0-9a-fA-F]+)\s+inst=(?P<inst>[0-9a-fA-F]+)\s+priv=(?P<priv>\d+)\s+rd_we=(?P<rd_we>[01])\s+rd=(?P<rd>\d+)\s+rd_data=(?P<rd_data>[0-9a-fA-F]+)\s+mem_valid=(?P<mem_valid>[01])\s+mem_write=(?P<mem_write>[01])\s+mem_addr=(?P<mem_addr>[0-9a-fA-F]+)\s+mem_mask=(?P<mem_mask>[0-9a-fA-F]+)\s+mem_data=(?P<mem_data>[0-9a-fA-F]+)$')
LOAD_ADDRESS_RE = re.compile(r'\[(?:0x)?([0-9a-fA-F]+)\]\s*$')

@dataclasses.dataclass(frozen=True)
class TraceEntry:
    source_order: int
    pc: int
    inst: int
    priv: int
    rd_we: bool
    rd: int
    rd_data: int
    mem_valid: bool
    mem_write: bool
    mem_addr: int
    mem_mask: Optional[int]
    mem_data: int
    text: str

def parse_int(value: str) -> int:
    return int(value, 16)

def whisper_priv_to_int(value: str) -> int:
    mapping = {'U': 0, 'S': 1, 'M': 3, 'u': 0, 's': 1, 'm': 3}
    if value not in mapping:
        raise ValueError(f'Unsupported Whisper privilege mode: {value}')
    return mapping[value]

def is_load_instruction(disasm: str) -> bool:
    mnemonic = disasm.strip().split(maxsplit=1)[0].lower()
    return mnemonic in {'lb','lbu','lh','lhu','lw','lwu','ld','lr.w','lr.d'}

def parse_whisper(lines: Iterable[str]) -> list[TraceEntry]:
    entries = []
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip('\n')
        m = WHISPER_RE.match(line)
        if not m:
            continue
        kind = m.group('kind')
        arg1 = parse_int(m.group('arg1'))
        arg2 = parse_int(m.group('arg2'))
        disasm = m.group('disasm')
        rd_we = False; rd = 0; rd_data = 0
        mem_valid = False; mem_write = False; mem_addr = 0; mem_mask = None; mem_data = 0
        if kind == 'm':
            mem_valid = True; mem_write = True; mem_addr = arg1; mem_data = arg2
        else:
            rd = arg1; rd_data = arg2; rd_we = rd != 0
            if is_load_instruction(disasm):
                am = LOAD_ADDRESS_RE.search(disasm)
                if am is None:
                    raise ValueError(f'Whisper load has no trailing [address] at line {line_number}: {line}')
                mem_valid = True; mem_write = False; mem_addr = parse_int(am.group(1)); mem_data = rd_data
        entries.append(TraceEntry(int(m.group('order')), parse_int(m.group('pc')), parse_int(m.group('inst')), whisper_priv_to_int(m.group('priv')), rd_we, rd if rd_we else 0, rd_data if rd_we else 0, mem_valid, mem_write, mem_addr if mem_valid else 0, mem_mask, mem_data if mem_valid else 0, line))
    if not entries:
        raise ValueError("No Whisper trace lines beginning with '#<number>' were found.")
    return entries

def parse_rtl(lines: Iterable[str]) -> list[TraceEntry]:
    entries = []
    for raw_line in lines:
        line = raw_line.rstrip('\n')
        m = RTL_RE.match(line)
        if not m:
            continue
        rd_we = m.group('rd_we') == '1'
        mem_valid = m.group('mem_valid') == '1'
        mem_write = m.group('mem_write') == '1'
        entries.append(TraceEntry(int(m.group('order')), parse_int(m.group('pc')), parse_int(m.group('inst')), int(m.group('priv')), rd_we, int(m.group('rd')) if rd_we else 0, parse_int(m.group('rd_data')) if rd_we else 0, mem_valid, mem_write if mem_valid else False, parse_int(m.group('mem_addr')) if mem_valid else 0, parse_int(m.group('mem_mask')) if mem_valid else 0, parse_int(m.group('mem_data')) if mem_valid else 0, line))
    if not entries:
        raise ValueError('No RTL [RETIRE] trace lines were found.')
    return entries

def select_pc_range(entries: list[TraceEntry], start_pc: Optional[int], stop_pc: Optional[int]) -> list[TraceEntry]:
    selected = []
    started = start_pc is None
    for entry in entries:
        if not started:
            if entry.pc != start_pc:
                continue
            started = True
        if stop_pc is not None and entry.pc == stop_pc:
            break
        selected.append(entry)
    if start_pc is not None and not started:
        raise ValueError(f'Start PC 0x{start_pc:x} was not found.')
    if not selected:
        raise ValueError('No trace entries remained after PC-range filtering.')
    return selected

def format_entry(e: TraceEntry) -> str:
    rd_text = f'x{e.rd}=0x{e.rd_data:016x}' if e.rd_we else 'no-rd-write'
    if not e.mem_valid:
        mem_text = 'no-memory'
    elif e.mem_write:
        mask_text = 'unknown' if e.mem_mask is None else f'0x{e.mem_mask:02x}'
        mem_text = f'store addr=0x{e.mem_addr:016x} mask={mask_text} data=0x{e.mem_data:016x}'
    else:
        mem_text = f'load addr=0x{e.mem_addr:016x} data=0x{e.mem_data:016x}'
    return f'pc=0x{e.pc:016x} inst=0x{e.inst:08x} priv={e.priv} {rd_text} {mem_text}'

def compare_entry(w: TraceEntry, r: TraceEntry) -> list[str]:
    diffs = []
    def check(name, a, b):
        if a != b:
            diffs.append(f'{name}: Whisper={a!r}, RTL={b!r}')
    check('pc', f'0x{w.pc:016x}', f'0x{r.pc:016x}')
    check('inst', f'0x{w.inst:08x}', f'0x{r.inst:08x}')
    check('priv', w.priv, r.priv)
    check('rd_we', w.rd_we, r.rd_we)
    if w.rd_we or r.rd_we:
        check('rd', w.rd, r.rd)
        check('rd_data', f'0x{w.rd_data:016x}', f'0x{r.rd_data:016x}')
    check('mem_valid', w.mem_valid, r.mem_valid)
    if w.mem_valid or r.mem_valid:
        check('mem_write', w.mem_write, r.mem_write)
        check('mem_addr', f'0x{w.mem_addr:016x}', f'0x{r.mem_addr:016x}')
        check('mem_data', f'0x{w.mem_data:016x}', f'0x{r.mem_data:016x}')
        if w.mem_mask is not None and r.mem_mask is not None:
            check('mem_mask', f'0x{w.mem_mask:02x}', f'0x{r.mem_mask:02x}')
    return diffs

def compare_traces(ws: list[TraceEntry], rs: list[TraceEntry]) -> int:
    common = min(len(ws), len(rs))
    for i in range(common):
        diffs = compare_entry(ws[i], rs[i])
        if diffs:
            print(f'FAIL: mismatch at compared instruction {i+1}', file=sys.stderr)
            print(f'Whisper source order: {ws[i].source_order}', file=sys.stderr)
            print(f'RTL source order:     {rs[i].source_order}', file=sys.stderr)
            print(f'Whisper: {format_entry(ws[i])}', file=sys.stderr)
            print(f'RTL:     {format_entry(rs[i])}', file=sys.stderr)
            print('Differences:', file=sys.stderr)
            for d in diffs:
                print(f'  - {d}', file=sys.stderr)
            print('Raw Whisper:', file=sys.stderr); print(f'  {ws[i].text}', file=sys.stderr)
            print('Raw RTL:', file=sys.stderr); print(f'  {rs[i].text}', file=sys.stderr)
            return 1
    if len(ws) != len(rs):
        print('FAIL: trace lengths differ', file=sys.stderr)
        print(f'Whisper entries: {len(ws)}', file=sys.stderr)
        print(f'RTL entries:     {len(rs)}', file=sys.stderr)
        if len(ws) > common:
            print(f'First extra Whisper entry:\n  {ws[common].text}', file=sys.stderr)
        if len(rs) > common:
            print(f'First extra RTL entry:\n  {rs[common].text}', file=sys.stderr)
        return 1
    print(f'PASS: {common} instructions matched (PC, instruction, privilege, register effects, memory effects).')
    return 0

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument('--whisper', required=True, type=Path)
    p.add_argument('--rtl', required=True, type=Path)
    p.add_argument('--start-pc')
    p.add_argument('--stop-pc')
    a = p.parse_args()
    try:
        ws = parse_whisper(a.whisper.read_text(encoding='utf-8', errors='replace').splitlines())
        rs = parse_rtl(a.rtl.read_text(encoding='utf-8', errors='replace').splitlines())
        start_pc = int(a.start_pc, 0) if a.start_pc else None
        stop_pc = int(a.stop_pc, 0) if a.stop_pc else None
        ws = select_pc_range(ws, start_pc, stop_pc)
        rs = select_pc_range(rs, start_pc, stop_pc)
        return compare_traces(ws, rs)
    except (OSError, ValueError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2

if __name__ == '__main__':
    raise SystemExit(main())
