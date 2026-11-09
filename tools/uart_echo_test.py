#!/usr/bin/env python3
"""G3 host-side test for the DE0-CV UART echo (115200 8N1, no flow control).

Design: fpga/de0-cv/UART_BOARD_ECHO_DESIGN.md section 7.

Safety rules implemented here:
  * The serial port must be given explicitly with --port; nothing is
    auto-selected. Without --port the tool only lists ports and exits non-zero.
  * The port's VID/PID/serial/description are recorded. If --expect-vid-pid is
    given and does not match, the tool stops; if it is not given, it records
    the identity and continues.
  * The port is opened with exclusive=True (POSIX advisory flock). This only
    excludes other cooperating programs that also lock the port; it is not a
    guarantee against every process. If the port is busy the tool stops and
    never kills other programs (screen, minicom, ...).
  * Every write is checked against its return value; every read loop has an
    overall deadline and accumulates partial reads; all data is compared in full.

Exit status: 0 only if every selected test passes.
"""
import argparse
import datetime
import os
import random
import sys
import time

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    sys.stderr.write("pyserial is missing: run tools/setup-uart-host-venv.sh and use "
                     "build/venv-uart/bin/python\n")
    sys.exit(2)

BAUD = 115200
BYTE_TIME = 10.0 / BAUD          # 8N1 frame time in seconds
DEFAULT_SEED = 20261109


class TestFailure(Exception):
    pass


class Log:
    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8")
        self.path = path

    def __call__(self, msg):
        line = f"{datetime.datetime.now().isoformat(timespec='milliseconds')} {msg}"
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()


def list_ports_text():
    rows = []
    for p in serial.tools.list_ports.comports():
        vidpid = f"{p.vid:04x}:{p.pid:04x}" if p.vid is not None else "----:----"
        rows.append(f"  {p.device}  vid:pid={vidpid}  serial={p.serial_number}  desc={p.description}")
    return "\n".join(rows) if rows else "  (no serial ports found)"


def port_identity(device):
    real = os.path.realpath(device)
    for p in serial.tools.list_ports.comports():
        if p.device in (device, real):
            return p
    return None


def write_all(ser, data, log):
    n = ser.write(data)
    if n != len(data):
        raise TestFailure(f"write returned {n}, expected {len(data)}")
    ser.flush()


def read_exact(ser, n, deadline_s):
    """Read exactly n bytes, accumulating partial reads, until an overall deadline."""
    buf = bytearray()
    t_end = time.monotonic() + deadline_s
    while len(buf) < n:
        remaining = t_end - time.monotonic()
        if remaining <= 0:
            break
        ser.timeout = min(0.5, remaining)
        chunk = ser.read(n - len(buf))
        buf.extend(chunk)
    return bytes(buf)


def compare(expected, got, what):
    if got == expected:
        return
    if len(got) != len(expected):
        detail = f"length {len(got)} != {len(expected)}"
    else:
        detail = "content differs"
    idx = next((i for i in range(min(len(got), len(expected))) if got[i] != expected[i]),
               min(len(got), len(expected)))
    lo = max(0, idx - 4)
    raise TestFailure(f"{what}: {detail}; first mismatch at {idx}: "
                      f"expected {expected[lo:idx + 4].hex(' ')} got {got[lo:idx + 4].hex(' ')}")


def expect_silence(ser, seconds, what):
    ser.timeout = seconds
    extra = ser.read(4096)
    if extra:
        raise TestFailure(f"{what}: {len(extra)} unexpected byte(s): {extra[:16].hex(' ')}")


def deadline_for(nbytes):
    return nbytes * BYTE_TIME * 1.5 + 1.0


def t_single(ser, log, rng):
    data = b"\x55"
    write_all(ser, data, log)
    compare(data, read_exact(ser, 1, deadline_for(1)), "single")


def t_all256(ser, log, rng):
    for v in range(256):
        b = bytes([v])
        write_all(ser, b, log)
        compare(b, read_exact(ser, 1, deadline_for(1)), f"value 0x{v:02x}")


def t_chunks(ser, log, rng):
    data = bytes(rng.randrange(256) for _ in range(4096))
    for off in range(0, len(data), 16):
        chunk = data[off:off + 16]
        write_all(ser, chunk, log)
        compare(chunk, read_exact(ser, len(chunk), deadline_for(len(chunk))), f"chunk @{off}")


def t_stream(ser, log, rng):
    # 4096 bytes is the test volume, not a guaranteed loss-free limit.
    data = bytes(rng.randrange(256) for _ in range(4096))
    write_all(ser, data, log)
    compare(data, read_exact(ser, len(data), deadline_for(len(data))), "stream 4096")


def t_silence(ser, log, rng):
    expect_silence(ser, 0.5, "silence")


def t_break(ser, log, rng):
    log("BREAK test: sending a 250 ms break; expect NO echo and LEDR4 (BREAK seen) lit. "
        "Press KEY0 afterwards to clear it.")
    ser.send_break(0.25)
    expect_silence(ser, 0.5, "break (must not echo)")


TESTS = [("single", t_single), ("all256", t_all256), ("chunks", t_chunks),
         ("stream", t_stream), ("silence", t_silence)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial device, e.g. /dev/cu.usbserial-XXXX (required)")
    ap.add_argument("--expect-vid-pid", help="optional VID:PID (hex) that the port must have, e.g. 0403:6001")
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--break-test", action="store_true", help="also run the BREAK diagnostic (operator checks LEDR4)")
    ap.add_argument("--log-dir", default="build/logs")
    args = ap.parse_args()

    if not args.port:
        sys.stderr.write("--port is required; no port is selected automatically. Available ports:\n")
        sys.stderr.write(list_ports_text() + "\n")
        return 2
    if not (args.port.startswith("/dev/cu.") or args.port.startswith("/dev/tty")):
        sys.stderr.write(f"refusing unexpected port path: {args.port}\n")
        return 2
    if not os.path.exists(args.port):
        sys.stderr.write(f"port does not exist: {args.port}\nAvailable ports:\n{list_ports_text()}\n")
        return 2

    os.makedirs(args.log_dir, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    log = Log(os.path.join(args.log_dir, f"uart-echo-{stamp}.log"))

    ident = port_identity(args.port)
    if ident is not None and ident.vid is not None:
        vidpid = f"{ident.vid:04x}:{ident.pid:04x}"
        log(f"port {args.port} vid:pid={vidpid} serial={ident.serial_number} "
            f"desc={ident.description} manufacturer={ident.manufacturer}")
    else:
        vidpid = None
        log(f"port {args.port}: no USB identity reported")
    if args.expect_vid_pid:
        if vidpid is None or vidpid.lower() != args.expect_vid_pid.lower():
            log(f"FAIL: expected vid:pid {args.expect_vid_pid}, port has {vidpid}")
            return 2
    log(f"baud={BAUD} 8N1 rtscts=0 xonxoff=0 seed={args.seed} pyserial={serial.__version__}")

    try:
        ser = serial.Serial(args.port, BAUD, bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                            stopbits=serial.STOPBITS_ONE, timeout=0.5, write_timeout=2.0,
                            rtscts=False, xonxoff=False, dsrdtr=False, exclusive=True)
    except serial.SerialException as e:
        log(f"FAIL: cannot open {args.port} exclusively ({e}). Close the other program yourself; "
            f"this tool never terminates other processes.")
        return 2

    rng = random.Random(args.seed)
    results = []
    tests = list(TESTS) + ([("break", t_break)] if args.break_test else [])
    try:
        time.sleep(0.1)
        ser.reset_input_buffer()
        for name, fn in tests:
            try:
                fn(ser, log, rng)
                results.append((name, True, ""))
                log(f"PASS {name}")
            except (TestFailure, serial.SerialTimeoutException) as e:
                results.append((name, False, str(e)))
                log(f"FAIL {name}: {e}")
                ser.reset_input_buffer()
    finally:
        ser.close()

    ok = all(r[1] for r in results)
    log(f"SUMMARY {'PASS' if ok else 'FAIL'}: " + ", ".join(f"{n}={'ok' if p else 'FAIL'}" for n, p, _ in results))
    log(f"log file: {log.path}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
