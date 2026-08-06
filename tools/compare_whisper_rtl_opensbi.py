#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import re
import sys
from pathlib import Path
from typing import Optional


WRE = re.compile(
    r'^#(?P<order>\d+)\s+'
    r'\d+\s+'
    r'(?P<priv>[A-Za-z]+)\s+'
    r'(?P<pc>[0-9a-fA-F]+)\s+'
    r'(?P<inst>[0-9a-fA-F]+)\s+'
    r'(?P<kind>[rmc])\s+'
    r'(?P<a1>[0-9a-fA-F]+)\s+'
    r'(?P<a2>[0-9a-fA-F]+)\s+'
    r'(?P<disasm>.*)$'
)

RRE = re.compile(
    r'^\[RETIRE\]\s+'
    r'order=(?P<order>\d+)\s+'
    r'pc=(?P<pc>[0-9a-fA-F]+)\s+'
    r'inst=(?P<inst>[0-9a-fA-F]+)\s+'
    r'priv=(?P<priv>\d+)\s+'
    r'rd_we=(?P<rd_we>[01])\s+'
    r'rd=(?P<rd>\d+)\s+'
    r'rd_data=(?P<rd_data>[0-9a-fA-F]+)\s+'
    r'mem_valid=(?P<mem_valid>[01])\s+'
    r'mem_write=(?P<mem_write>[01])\s+'
    r'mem_addr=(?P<mem_addr>[0-9a-fA-F]+)\s+'
    r'mem_mask=(?P<mem_mask>[0-9a-fA-F]+)\s+'
    r'mem_data=(?P<mem_data>[0-9a-fA-F]+)$'
)

ADDR_RE = re.compile(r'\[(?:0x)?([0-9a-fA-F]+)\]')

LOADS = {
    # Base integer loads
    'lb',
    'lbu',
    'lh',
    'lhu',
    'lw',
    'lwu',
    'ld',

    # Compressed loads
    'c.lw',
    'c.ld',
    'c.lwsp',
    'c.ldsp',

    # Atomic load-reserved
    'lr.w',
    'lr.d',
}


@dataclasses.dataclass
class E:
    order: int
    pc: int
    inst: int
    compressed: bool
    priv: int

    rd_we: bool = False
    rd: int = 0
    rd_data: int = 0

    mem_valid: bool = False
    mem_write: bool = False
    mem_addr: int = 0
    mem_mask: int = 0
    mem_data: int = 0

    raw: list[str] = dataclasses.field(default_factory=list)


def hx(s: str) -> int:
    return int(s, 16)


def priv(s: str) -> int:
    return {
        'U': 0,
        'S': 1,
        'M': 3,
        'u': 0,
        's': 1,
        'm': 3,
    }[s]


def mnem(s: str) -> str:
    if not s.strip():
        return ''
    return s.strip().split(maxsplit=1)[0].lower()


def parse_w(path: Path) -> list[E]:
    by_order: dict[int, E] = {}
    seq: list[int] = []

    for line_number, line in enumerate(
        path.read_text(errors='replace').splitlines(),
        start=1,
    ):
        match = WRE.match(line)
        if not match:
            continue

        order = int(match['order'])
        pc = hx(match['pc'])
        inst = hx(match['inst'])
        kind = match['kind']
        a1 = hx(match['a1'])
        a2 = hx(match['a2'])
        disasm = match['disasm']

        if order not in by_order:
            by_order[order] = E(
                order=order,
                pc=pc,
                inst=inst,
                compressed=len(match['inst']) <= 4,
                priv=priv(match['priv']),
            )
            seq.append(order)

        entry = by_order[order]

        if entry.pc != pc:
            raise ValueError(
                f'Whisper order {order} has inconsistent PCs: '
                f'0x{entry.pc:x} vs 0x{pc:x}'
            )

        entry.raw.append(line)

        if kind == 'r':
            entry.rd_we = a1 != 0
            entry.rd = a1 if entry.rd_we else 0
            entry.rd_data = a2 if entry.rd_we else 0

            if mnem(disasm) in LOADS:
                address_match = ADDR_RE.search(disasm)

                if not address_match:
                    raise ValueError(
                        f'Load address missing at line {line_number}: {line}'
                    )

                entry.mem_valid = True
                entry.mem_write = False
                entry.mem_addr = hx(address_match.group(1))
                entry.mem_mask = 0
                entry.mem_data = a2

        elif kind == 'm':
            entry.mem_valid = True
            entry.mem_write = True
            entry.mem_addr = a1

            # Whisper stores are represented as a right-aligned store value.
            # Whisper does not provide the RTL bus byte mask directly.
            entry.mem_mask = 0
            entry.mem_data = a2

        elif kind == 'c':
            # CSR architectural state is not yet present in the RTL trace.
            #
            # Whisper's "c" line describes a CSR effect, not necessarily a
            # general-purpose register write. For the current comparison,
            # compare PC, instruction, and privilege, but treat the GPR effect
            # as no write.
            entry.rd_we = False
            entry.rd = 0
            entry.rd_data = 0

    if not seq:
        raise ValueError('No Whisper trace entries found')

    return [by_order[order] for order in seq]


def parse_r(path: Path) -> list[E]:
    out: list[E] = []

    for line in path.read_text(errors='replace').splitlines():
        match = RRE.match(line)
        if not match:
            continue

        rd_we = match['rd_we'] == '1'
        mem_valid = match['mem_valid'] == '1'
        mem_write = match['mem_write'] == '1'

        entry = E(
            order=int(match['order']),
            pc=hx(match['pc']),
            inst=hx(match['inst']),
            compressed=False,
            priv=int(match['priv']),
        )

        entry.rd_we = rd_we
        entry.rd = int(match['rd']) if rd_we else 0
        entry.rd_data = hx(match['rd_data']) if rd_we else 0

        entry.mem_valid = mem_valid
        entry.mem_write = mem_write if mem_valid else False
        entry.mem_addr = hx(match['mem_addr']) if mem_valid else 0
        entry.mem_mask = hx(match['mem_mask']) if mem_valid else 0
        entry.mem_data = hx(match['mem_data']) if mem_valid else 0

        entry.raw = [line]
        out.append(entry)

    if not out:
        raise ValueError('No RTL trace entries found')

    return out


def select(
    entries: list[E],
    start: Optional[int],
    stop: Optional[int],
    count: Optional[int],
) -> list[E]:
    out: list[E] = []
    active = start is None

    for entry in entries:
        if not active:
            if entry.pc != start:
                continue
            active = True

        if stop is not None and entry.pc == stop:
            break

        out.append(entry)

        if count is not None and len(out) >= count:
            break

    if start is not None and not active:
        raise ValueError(f'Start PC 0x{start:x} not found')

    if not out:
        raise ValueError('No entries after filtering')

    return out


def normalize_store_data(data: int, mask: int) -> int:
    """
    Convert RTL bus-lane-aligned store data into a right-aligned store value.

    Example:

        RTL:
            mask = 0xf0
            data = 0xfffffff800000000

        Normalized:
            0x00000000fffffff8

    This matches Whisper's store-data representation.
    """
    result = 0
    output_byte_index = 0

    for lane in range(8):
        if mask & (1 << lane):
            byte_value = (data >> (lane * 8)) & 0xff
            result |= byte_value << (output_byte_index * 8)
            output_byte_index += 1

    return result


def compare(
    whisper: E,
    rtl: E,
    ignore_inst: bool,
) -> list[str]:
    differences: list[str] = []

    def check(name: str, whisper_value: object, rtl_value: object) -> None:
        if whisper_value != rtl_value:
            differences.append(
                f'{name}: Whisper={whisper_value}, RTL={rtl_value}'
            )

    check(
        'pc',
        f'0x{whisper.pc:016x}',
        f'0x{rtl.pc:016x}',
    )

    # Whisper displays the original 16-bit encoding for RVC instructions.
    # RTL currently displays the expanded 32-bit instruction.
    if not ignore_inst and not whisper.compressed:
        check(
            'inst',
            f'0x{whisper.inst:08x}',
            f'0x{rtl.inst:08x}',
        )

    check('priv', whisper.priv, rtl.priv)
    check('rd_we', whisper.rd_we, rtl.rd_we)

    if whisper.rd_we or rtl.rd_we:
        check('rd', whisper.rd, rtl.rd)
        check(
            'rd_data',
            f'0x{whisper.rd_data:016x}',
            f'0x{rtl.rd_data:016x}',
        )

    check('mem_valid', whisper.mem_valid, rtl.mem_valid)

    if whisper.mem_valid or rtl.mem_valid:
        check('mem_write', whisper.mem_write, rtl.mem_write)

        check(
            'mem_addr',
            f'0x{whisper.mem_addr:016x}',
            f'0x{rtl.mem_addr:016x}',
        )

        if whisper.mem_write and rtl.mem_write:
            normalized_rtl_data = normalize_store_data(
                rtl.mem_data,
                rtl.mem_mask,
            )

            check(
                'mem_data',
                f'0x{whisper.mem_data:016x}',
                f'0x{normalized_rtl_data:016x}',
            )
        else:
            check(
                'mem_data',
                f'0x{whisper.mem_data:016x}',
                f'0x{rtl.mem_data:016x}',
            )

    return differences


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        '--whisper',
        required=True,
        type=Path,
    )

    parser.add_argument(
        '--rtl',
        required=True,
        type=Path,
    )

    parser.add_argument('--start-pc')
    parser.add_argument('--stop-pc')
    parser.add_argument('--count', type=int)

    parser.add_argument(
        '--ignore-inst',
        action='store_true',
        help='Ignore instruction-bit comparison for all instructions.',
    )

    args = parser.parse_args()

    try:
        start_pc = int(args.start_pc, 0) if args.start_pc else None
        stop_pc = int(args.stop_pc, 0) if args.stop_pc else None

        whisper_entries = select(
            parse_w(args.whisper),
            start_pc,
            stop_pc,
            args.count,
        )

        rtl_entries = select(
            parse_r(args.rtl),
            start_pc,
            stop_pc,
            args.count,
        )

        for index, (whisper, rtl) in enumerate(
            zip(whisper_entries, rtl_entries),
            start=1,
        ):
            differences = compare(
                whisper,
                rtl,
                args.ignore_inst,
            )

            if differences:
                print(
                    f'FAIL: mismatch at compared instruction {index}',
                    file=sys.stderr,
                )

                print(
                    f'Whisper order={whisper.order} '
                    f'RTL order={rtl.order}',
                    file=sys.stderr,
                )

                for difference in differences:
                    print(
                        f'  - {difference}',
                        file=sys.stderr,
                    )

                print('Whisper:', file=sys.stderr)
                for raw_line in whisper.raw:
                    print(
                        f'  {raw_line}',
                        file=sys.stderr,
                    )

                print('RTL:', file=sys.stderr)
                for raw_line in rtl.raw:
                    print(
                        f'  {raw_line}',
                        file=sys.stderr,
                    )

                return 1

        if len(whisper_entries) != len(rtl_entries):
            print(
                'FAIL: trace lengths differ: '
                f'Whisper={len(whisper_entries)} '
                f'RTL={len(rtl_entries)}',
                file=sys.stderr,
            )
            return 1

        compressed_count = sum(
            entry.compressed
            for entry in whisper_entries
        )

        print(
            f'PASS: {len(whisper_entries)} instructions matched '
            f'(including {compressed_count} RVC instructions; '
            f'PC, privilege, register effects, memory effects).'
        )

        return 0

    except (OSError, ValueError, KeyError) as error:
        print(
            f'ERROR: {error}',
            file=sys.stderr,
        )
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
