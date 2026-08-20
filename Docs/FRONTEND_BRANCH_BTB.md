# Frontend Branch BTB Optimization

Last updated: 2026-08-20

This document summarizes the Phase 11 frontend optimization work in MiNTs-CPU:
fetch-side conditional branch BTB lookup, fetch/issue FIFO bypass, and I-cache
response-to-next-request handoff.

## Summary

MiNTs-CPU already had early branch resolution and a 2-bit direction predictor.
The remaining frontend cost was that a correct taken-branch prediction was
still applied late, after the branch instruction had been fetched and issued.

The first new path trains the existing BTB with taken conditional branch
targets and lets fetch use that target directly from the fetch PC. EX-stage
branch resolution remains the architectural truth; the fetch-side BTB is only a
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

The follow-up work removed another fixed frontend bubble. The tight loop target
often lands in the upper half of an 8-byte fetch block. After issuing that one
useful instruction, the next instruction is in the following 8-byte block. The
I-cache used to return the current response in one cycle and accept the next
request only later. The current implementation can consume the response and
accept the next sequential request in the same cycle when the fetch path is
ready.

```text
before:
  I-cache response
  -> issue target instruction
  -> next-cycle request for following block

after:
  I-cache response
  -> issue target instruction
  -> same-cycle request for following block
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

Initial MiNTs-CPU result after fetch-side branch BTB:

```text
variant   before cycles   after cycles   saved cycles
1x                 90013          80015           9998
2x                 75025          70027           4998
4x                 67537          65039           2498
```

The improvement scales with the number of loop-back branches, so this change
removes about one cycle of frontend overhead per trained taken branch in this
benchmark.

Final MiNTs-CPU result after fetch/issue FIFO bypass and I-cache follow-on
request:

```text
variant   Rocket cycles   MiNTs cycles   MiNTs instret
1x              70045          70014          70002
2x              65042          65026          65002
4x              62545          62538          62502
```

This brings the controlled common assembly benchmark to practical parity with
Rocket for this loop. It does not mean the full cores are equivalent; it means
the previously visible branch-frequency-proportional frontend bubble in this
specific benchmark has been removed.

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

Representative result after the Phase 11 frontend work:

```text
[PERF-FETCH-STALL] fifo_full=7320628 control_recovery=14156540 translation_issue=19680007 translation_req_wait=0 translation_rsp=22023 icache_req=2586028 icache_rsp=5765099 fault=0 no_request=0
[PERF-CONTROL] branch=1246862 jal=726042 jalr=127390 trap=1611 return=1679 satp=13 sfence=2000 other=0
[PERF-BPRED] pred=5561110 hit=4314232 miss=1246878 hit_rate_x1000=775
[PERF-BTB] jalr=421644 hit=294253 miss=127391 hit_rate_x1000=697 entries=32
[PERF-RAS] return=352959 hit=275654 miss=77305 fallback_btb=131 hit_rate_x1000=780 depth=8
[PERF] cycles=100000000 retired=41780831 cpi_x1000=2393 ipc_x1000=417
[PERF] primary commit=41780831 no_commit=58219169 mem=13905496 muldiv=3334258 data_hazard=699897 ifetch=16160494 other=24119024
```

Comparison against the previous stable write-through checkpoint:

```text
metric              before      after       delta
retired           39,534,138  41,780,831  +2,246,693
CPI x1000              2529        2393       -136
IPC x1000               395         417        +22
primary ifetch   19,749,634  16,160,494  -3,589,140
primary mem      13,068,681  13,905,496    +836,815
```

The Linux result is smaller than the branch-dense microbenchmark result, but it
is still significant: CPI improves from about 2.529 to 2.393 on the same
100M-cycle boot workload. The primary ifetch bucket drops by about 3.6M cycles,
while MEM pressure becomes more visible after the frontend removes bubbles.

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
Whisper lockstep  PASS
```

## Remaining Work

The common assembly benchmark no longer shows the earlier branch-frequency
proportional gap against Rocket. Remaining frontend work should now focus on
broader Linux workloads and predictor quality, especially cases where BTB/RAS
accuracy changes after fetch scheduling improvements.
