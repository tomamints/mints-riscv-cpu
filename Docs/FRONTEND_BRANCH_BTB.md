# Frontend Branch BTB Optimization

Last updated: 2026-08-20

This document summarizes the fetch-side conditional branch BTB optimization in
MiNTs-CPU.

## Summary

MiNTs-CPU already had early branch resolution and a 2-bit direction predictor.
The remaining frontend cost was that a correct taken-branch prediction was
still applied late, after the branch instruction had been fetched and issued.

The new path trains the existing BTB with taken conditional branch targets and
lets fetch use that target directly from the fetch PC. EX-stage branch
resolution remains the architectural truth; the fetch-side BTB is only a
prediction hint.

```text
before:
  fetch instruction
  -> decode/issue branch
  -> predictor says taken
  -> redirect fetch

after:
  fetch PC
  -> BTB/PHT lookup
  -> fetch predicted target block earlier
  -> EX verifies prediction
```

## Common Assembly Benchmark

The controlled benchmark is a hand-written ALU loop shared with the Rocket
comparison environment. The 1x loop body is:

```asm
xor     t0, t0, t1
slli    t4, t0, 7
srli    t0, t0, 57
or      t0, t0, t4
addi    t1, t1, 1
add     t0, t0, t2
bne     t1, t3, 1b
```

The same logical work is also measured with 2x and 4x unrolling. Reducing the
number of loop-back branches proportionally reduced MiNTs-CPU's original gap,
which identified taken-branch frontend cost as the main bottleneck for this
microbenchmark.

MiNTs-CPU result:

```text
variant   before cycles   after cycles   saved cycles
1x                 90013          80015           9998
2x                 75025          70027           4998
4x                 67537          65039           2498
```

The improvement scales with the number of loop-back branches, so this change
removes about one cycle of frontend overhead per trained taken branch in this
benchmark.

## Linux 100M Checkpoint

Configuration:

```text
OpenSBI + Linux 6.12 BusyBox cmdloop initramfs
cycles              100,000,000
D-cache             512 lines x 32 B
Store buffer        8 entries
D-cache policy      write-through
plusargs            +PERF_SUMMARY
```

Representative result after fetch-side branch BTB:

```text
[PERF] cycles=100000000 retired=40260939 cpi_x1000=2483 ipc_x1000=402
[PERF] primary commit=40260939 no_commit=59739061 mem=13377136 muldiv=3332661 data_hazard=702601 ifetch=19140744 other=23185919
[PERF-BPRED] pred=5292133 hit=4463782 miss=828351 hit_rate_x1000=843
[PERF-BTB] jalr=420410 hit=353227 miss=67183 hit_rate_x1000=840 entries=32
```

Comparison against the previous stable write-through checkpoint:

```text
metric              before      after       delta
retired           39,534,138  40,260,939   +726,801
CPI x1000              2529        2483        -46
IPC x1000               395         402         +7
primary ifetch   19,749,634  19,140,744   -608,890
primary mem      13,068,681  13,377,136   +308,455
```

The Linux result is smaller than the branch-dense microbenchmark result, but it
is still measurable: CPI improves from about 2.529 to 2.483 on the same
100M-cycle boot workload.

## Correctness Notes

The optimization required explicit `fence.i` handling for frontend prediction
state. `fence.i` can follow instruction-memory modification, so the branch
predictor must not keep stale BTB/PHT/RAS state across that boundary.

MiNTs-CPU treats `fence.i` as a precise MEM-stage frontend invalidation event:

```text
fence.i reaches MEM
  -> redirect fetch to fence.i + 4
  -> invalidate I-cache
  -> invalidate branch predictor state
```

Validation after the fix:

```text
make build        PASS
rv64ui-p-fence_i PASS
make test-rv64ui 54 / 54 PASS
make test-output  PASS
```

## Remaining Work

The common assembly benchmark still shows a branch-frequency-proportional gap
after this change. The next frontend target is the remaining taken-branch
bubble and any fixed fetch/issue FIFO bubble that still appears after a correct
BTB prediction.
