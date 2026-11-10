#!/usr/bin/env python3
"""Classify the directed fence.i / posted-store test from one simulator log.

usage: analyze-fence-i-trace.py <sim log> <symbols file> <trace: 0|1>

Inputs: the simulator log (+TRACE_RETIRE; with trace=1 also the RAM shim trace
and RAM_SHIM_FENCE events) and `hexaddr name` symbol lines (17 expected).
Per executed slot k it reports the retired instruction at patch_k (new / stale),
the actual fence.i invalidate cycle (RAM_SHIM_FENCE, shim time base), the patch
write accept / performed cycles with data/mask coverage of the new instruction,
reads of the patch word after the slot marker, and OVERTAKE = a read accepted
after the invalidate and before the write was performed.

Verdict (first line) and exit status:
  PASS            exit 0  all 16 patches retired NEW exactly once, tohost=1;
                          with trace: one fence event per slot, no post-fence
                          read before the write is performed, and a refetch
                          of the patch word after it
  COUNTEREXAMPLE  exit 0  tohost reports slot k, patch_k retired STALE
  INVALID         exit 2  missing RETIRE/symbols/fence events, timeout,
                          inconsistent outcome, or unclassifiable log
Slots after the first failing slot are not executed and not required.
"""
import re
import sys

RAM_BASE = 0x80000000
NEW, STALE = 0x00100513, 0x00000513


def invalid(msg, lines):
    print("INVALID " + msg)
    for line in lines:
        print(line)
    sys.exit(2)


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("0", "1"):
        print("usage: analyze-fence-i-trace.py <sim log> <symbols file> <trace: 0|1>\n"
              "  trace=1: the log has the RAM shim trace and RAM_SHIM_FENCE events\n"
              "  trace=0: shim-off simulator; classification from RETIRE/tohost only",
              file=sys.stderr)
        sys.exit(2)
    log_path, sym_path, trace_on = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
    syms = {}
    for line in open(sym_path):
        parts = line.split()
        if len(parts) == 2:
            syms[parts[1]] = int(parts[0], 16)
    names = [f"patch_{k}" for k in range(16)] + ["markers"]
    if sorted(syms) != sorted(names):
        invalid(f"symbols: expected 17 (patch_0..15, markers), got {sorted(syms)}", [])
    patches = {k: syms[f"patch_{k}"] for k in range(16)}
    markers = syms["markers"]

    retire, trace, fences = [], [], []
    tohost = None
    rx_ret = re.compile(r"\[RETIRE\] cycle=(\d+) order=\d+ pc=([0-9a-f]+) inst=([0-9a-f]+)")
    rx_tr = re.compile(r"RAM_SHIM_TRACE cyc=(\d+) ev=(\w+) wen=(\d) addr=([0-9a-f]+) wdata=([0-9a-f]+) wmask=([0-9a-f]+)")
    rx_fe = re.compile(r"RAM_SHIM_FENCE cyc=(\d+) core_cycle=(\d+) pc=([0-9a-f]+)")
    rx_th = re.compile(r"wdata : ([0-9a-f]+)")
    for line in open(log_path, errors="replace"):
        if (m := rx_ret.search(line)):
            retire.append((int(m[1]), int(m[2], 16), int(m[3], 16)))
        elif (m := rx_tr.search(line)):
            trace.append((int(m[1]), m[2], m[3] == "1", int(m[4], 16), int(m[5], 16), int(m[6], 16)))
        elif (m := rx_fe.search(line)):
            fences.append((int(m[1]), int(m[2]), int(m[3], 16)))
        elif (m := rx_th.search(line)):
            if tohost is not None:
                invalid("more than one tohost result", [])
            tohost = int(m[1], 16)
        elif "test success!" in line:
            if tohost is not None:
                invalid("more than one tohost result", [])
            tohost = 1  # top.sv prints this instead of the wdata line on tohost == 1

    out = []
    if not retire:
        invalid("no [RETIRE] lines (missing +TRACE_RETIRE?)", out)
    if tohost is None:
        invalid("no tohost value (timeout or abnormal end)", out)
    for f in fences:
        if f[0] != f[1]:
            invalid(f"time base mismatch: shim cyc={f[0]} core_cycle={f[1]}", out)
    out.append(f"tohost={tohost:#x} fences={len(fences)} trace_events={len(trace)} retires={len(retire)}")

    if tohost == 1:
        executed = list(range(16))
        failing = None
    elif tohost & 1 and 1 <= (tohost >> 1) <= 16:
        failing = (tohost >> 1) - 1
        executed = list(range(failing + 1))
    else:
        invalid(f"unexpected tohost {tohost:#x}", out)

    stale_slots = []
    for k in executed:
        pc = patches[k]
        ret = [r for r in retire if r[1] == pc]
        kinds = [{NEW: "new", STALE: "stale"}.get(r[2], f"{r[2]:#x}") for r in ret]
        if len(ret) != 1:
            invalid(f"slot {k}: patch retired {len(ret)} times ({kinds})", out)
        kind = kinds[0]
        if kind == "stale":
            stale_slots.append(k)
        line = f"slot {k:2d} pc={pc:08x} lane={'hi' if pc & 4 else 'lo'} lineoff={pc & 31:2d} retired={kind}@{ret[0][0]}"
        if trace_on:
            fe = [f[0] for f in fences if f[2] == pc - 4]
            if len(fe) != 1:
                invalid(f"slot {k}: expected one fence.i invalidate event at pc {pc - 4:#x}, got {len(fe)}", out)
            fence_cyc = fe[0]
            word = (pc - RAM_BASE) & ~7
            lane = (pc - RAM_BASE) & 7
            moff = markers - RAM_BASE + 8 * k
            m_acc = [t[0] for t in trace if t[1] == "ACC" and t[2] and t[3] == moff]
            if not m_acc:
                invalid(f"slot {k}: no marker write in trace", out)
            start = m_acc[0]
            writes = [t for t in trace if t[1] == "ACC" and t[2] and (t[3] & ~7) == word and t[0] > start]
            if len(writes) != 1:
                invalid(f"slot {k}: expected one patch write after the marker, got {len(writes)}", out)
            w = writes[0]
            covers = all((w[5] >> (lane + i)) & 1 for i in range(4)) and ((w[4] >> (8 * lane)) & 0xFFFFFFFF) == NEW
            if not covers:
                invalid(f"slot {k}: patch write wdata={w[4]:#x} wmask={w[5]:#x} does not carry the new instruction", out)
            perf = [t[0] for t in trace if t[1] == "DRSP" and t[2] and (t[3] & ~7) == word and t[0] >= w[0]]
            performed = perf[0] if perf else None
            reads = [t[0] for t in trace if t[1] == "ACC" and not t[2] and (t[3] & ~7) == word and t[0] > start]
            post = [c for c in reads if c >= fence_cyc]
            overtake = [c for c in post if performed is None or c < performed]
            if failing is None:
                # PASS requires the causal proof, not only the test result:
                # no post-invalidate read of the patch word before the write was
                # performed, and the refetch that supplied NEW came after it.
                if overtake:
                    invalid(f"slot {k}: tohost=1 but post-fence read(s) {overtake} precede write performed {performed}", out)
                if performed is None or not [c for c in post if c > performed]:
                    invalid(f"slot {k}: tohost=1 but no refetch of the patch word after the write was performed ({performed})", out)
            line += (f" marker_acc={start} fence_inval={fence_cyc} write_acc={w[0]} write_performed={performed}"
                     f" reads_after_marker={reads} post_fence_reads={post} OVERTAKE={'yes' if overtake else 'no'}")
        out.append(line)

    if failing is None:
        if stale_slots:
            invalid(f"tohost=1 but stale retired in slots {stale_slots}", out)
        verdict = "PASS all 16 patches retired NEW exactly once"
    else:
        if stale_slots != [failing]:
            invalid(f"tohost slot {failing} but stale slots {stale_slots}", out)
        verdict = f"COUNTEREXAMPLE slot {failing} (TESTNUM {failing + 1}) retired STALE"
    print(verdict)
    for line in out:
        print(line)
    sys.exit(0)


if __name__ == "__main__":
    main()
