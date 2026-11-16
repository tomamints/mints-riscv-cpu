#!/usr/bin/env python3
"""Native C executable checked against an independent modulo-index Python model."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent

def reference(count):
    state = 0x4D494E54
    grid = []
    for _ in range(16):
        row = []
        for _ in range(32):
            state ^= (state << 13) & 0xFFFFFFFF
            state ^= state >> 17
            state ^= (state << 5) & 0xFFFFFFFF
            row.append(int((state & 3) == 0))
        grid.append(row)
    for _ in range(count):
        grid = [[int((n := sum(grid[(y + dy) % 16][(x + dx) % 32]
                              for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                              if dx or dy)) == 3 or (grid[y][x] and n == 2))
                 for x in range(32)] for y in range(16)]
    checksum = 14695981039346656037
    for row in grid:
        for cell in row:
            checksum = ((checksum ^ cell) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f'{checksum:016x}'

with tempfile.TemporaryDirectory(prefix='mints-life-') as out:
    binary = str(Path(out) / 'life')
    subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
                   ['-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                    str(root / 'examples/life/life.c'), '-o', binary], check=True)
    assert subprocess.check_output([binary, '--self-test'], text=True).strip() == 'LIFE-SELFTEST-PASS'
    for count in (1, 2, 4, 20, 100):
        result = subprocess.check_output([binary, '--bench', str(count)], text=True)
        assert re.search(r'^Checksum: ([0-9a-f]+)$', result, re.M)[1] == reference(count), count
        assert f'Cell updates: {512 * count}\n' in result
    demo = subprocess.check_output([binary, '--demo', '1'], text=True)
    assert f'Checksum: {reference(1)}\n' in demo
    assert 'generation 0' in demo and 'generation 1' in demo
    for args in ([], ['--bad'], ['--bench', '0'], ['--bench', '-1'],
                 ['--bench', '1000001'], ['--bench', 'abc'], ['--bench', '1', 'extra']):
        assert subprocess.run([binary, *args], capture_output=True).returncode == 2, args
print('LIFE TEST PASS: independent reference, wrapping patterns, demo and argument validation')
