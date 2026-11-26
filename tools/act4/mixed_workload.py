"""Generate a seeded RV64 workload and compare its retire PC/GPR trace with Sail."""

import argparse
from itertools import zip_longest
from pathlib import Path
import random
import re


def generate(seed, count):
    rng = random.Random(seed)
    print("""
    .option norvc
    .option norelax
    .section .text.init, "ax"
    .globl _start, trace_end
_start:
    j setup
trap:
    csrr t1, mcause
    csrr t2, mtval
    csrr t3, mepc
    addi t3, t3, 4
    csrw mepc, t3
    mret
setup:
    la t0, trap
    csrw mtvec, t0
    la s0, scratch""")
    for reg in range(10, 18):
        print(f"    li x{reg}, {rng.randrange(-1024, 1024)}")
    for _ in range(count):
        reg, src = rng.sample(range(10, 18), 2)
        imm = rng.randrange(-16, 16)
        offset = 8 * rng.randrange(8)
        kind = rng.randrange(6)
        if kind == 0:
            op = rng.choice(("add", "sub", "xor", "mul"))
            print(f"    {op} x{reg}, x{reg}, x{src}")
        elif kind == 1:
            print(f"    sd x{src}, {offset}(s0)\n    ld x{reg}, {offset}(s0)")
        elif kind == 2:
            print(f"    .option push\n    .option rvc\n    c.addi x{reg}, {imm or 1}\n    .option pop")
        elif kind == 3:
            print(f"    csrrw x{reg}, mscratch, x{src}\n    csrr x{src}, mscratch")
        elif kind == 4:
            print(f"    beq x{reg}, x{src}, 1f\n    addi x{reg}, x{reg}, {imm}\n1:")
        else:
            print("    ecall")
    print("""
trace_end:
    la t0, tohost
    li t1, 1
1:  sw t1, 0(t0)
    j 1b
    .section .tohost, "aw"
    .balign 8
    .globl tohost
tohost: .dword 0
scratch: .zero 64""")


def sail_events(lines, end):
    pc = None
    reg, value = 0, 0
    for line in lines:
        inst = re.match(r"\[\d+\] \[M\]: (0x[\da-f]+) \((0x[\da-f]+)\)", line, re.I)
        if inst:
            if pc is not None:
                yield pc, reg, value
            pc = int(inst[1], 16)
            if pc == end:
                return
            # Sail traces ECALL before taking the trap. It does not retire.
            if int(inst[2], 16) == 0x73:
                pc = None
            reg, value = 0, 0
        write = re.match(r"x([1-9]\d*) <- (0x[\da-f]+)", line, re.I)
        if write:
            reg, value = int(write[1]), int(write[2], 16)
    raise SystemExit("Sail did not reach trace_end")


def rtl_events(lines, end):
    for line in lines:
        if not line.startswith("[RETIRE] "):
            continue
        fields = dict(part.split("=") for part in line.split()[1:])
        pc = int(fields["pc"], 16)
        if pc < 0x80000000:  # Simulator boot ROM.
            continue
        if pc == end:
            return
        yield pc, int(fields["rd"]), int(fields["rd_data"], 16)
    raise SystemExit("MiNTs did not reach trace_end")


def compare(sail, rtl, end):
    with sail.open() as expected, rtl.open() as observed:
        events = zip_longest(sail_events(expected, end), rtl_events(observed, end))
        count = 0
        for count, (ref, dut) in enumerate(events, 1):
            if ref != dut:
                def fmt(event):
                    return "end" if event is None else f"PC 0x{event[0]:x}, x{event[1]}=0x{event[2]:x}"
                raise SystemExit(f"Retire event {count}: Sail {fmt(ref)}, MiNTs {fmt(dut)}")
    if count == 0:
        raise SystemExit("No retire events compared")
    print(f"RV64 differential PASS: {count} ordered retire PCs and GPR effects")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    gen = commands.add_parser("generate")
    gen.add_argument("seed", type=int)
    gen.add_argument("count", type=int)
    diff = commands.add_parser("compare")
    diff.add_argument("sail", type=Path)
    diff.add_argument("rtl", type=Path)
    diff.add_argument("end", type=lambda value: int(value, 16))
    args = parser.parse_args()
    if args.command == "generate":
        generate(args.seed, args.count)
    else:
        compare(args.sail, args.rtl, args.end)
