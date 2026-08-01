# Linux TTY/UART Current Issue

Date: 2026-08-01

## Current Symptom

The system boots through OpenSBI and Linux, then starts `/init`.

Observed prompt path:

```text
Run /init as init process
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

When typing:

```text
echo OK
```

the UART RX path receives all bytes, but the shell does not reliably reach:

```text
MARK-C: read returned
line=[echo OK]
OK
```

In recent traces, the input bytes are visible up to RBR reads:

```text
e     0x65
c     0x63
h     0x68
o     0x6f
space 0x20
O     0x4f
K     0x4b
LF    0x0a
```

However, TTY echo / shell read completion does not consistently continue after the bytes are read.

## Confirmed Working

The latest UART/PLIC trace shows this sequence for each input byte:

```text
UART irq source=1
PLIC pending=1
PLIC CLAIM irq=10
UART IIR = c4
UART LSR = 61
UART RBR = input byte
UART irq source=0
PLIC COMPLETE irq=10
PLIC in_service=0
PLIC seip=0
```

This strongly suggests the following are working for the observed input:

```text
host input delivery
UART RX storage
UART RX interrupt indication
Linux 8250 IIR read
Linux 8250 LSR read
Linux 8250 RBR read
PLIC pending
PLIC claim
PLIC complete
SEIP deassertion after complete
```

## Recent Hardware Fixes

### UART MMIO handshake

UART now uses a `bus_wait_valid_low` guard so one held `membus.valid` request is accepted once.

Reason:

```text
RBR read has side effects.
THR write has side effects.
The same MMIO transaction must not pop/write multiple times.
```

### UART TX interrupt behavior

TX pending is no longer cleared by IIR read. It is cleared by the next THR write.

LSR now always reports TX empty:

```text
LSR.THRE = 1
LSR.TEMT = 1
```

This matches the current zero-latency `$write()` TX model better.

### PLIC MMIO handshake

PLIC now also uses a `bus_wait_valid_low` guard.

Reason:

```text
PLIC claim read has side effects.
PLIC complete write has side effects.
The same held valid request must not be processed multiple times.
```

The level interrupt logic itself was not changed:

```systemverilog
pending <= pending | (source_irq & ~in_service);
```

## Current Interpretation

The latest evidence no longer points first at UART RX or simple PLIC delivery.

The likely failing region is after `serial8250` has read RBR:

```text
serial8250 RX handling
  -> tty flip buffer
  -> tty_flip_buffer_push()
  -> workqueue / scheduler
  -> flush_to_ldisc()
  -> n_tty_receive_buf_common()
  -> canonical newline handling
  -> read() wakeup/return
```

This does not mean Linux itself is likely wrong. More likely, Linux is depending on CPU/interrupt/atomic/scheduler behavior that the current hardware model does not fully satisfy.

## Important Distinction

Current conclusion is not:

```text
Linux source is probably buggy.
```

Current conclusion is:

```text
Linux reaches the TTY path, but the post-RBR path does not reliably progress on this CPU/SoC model.
We need Linux-side trace to identify which hardware assumption is being violated.
```

## Next Minimal Trace

Do not add broad traces. The next useful trace should mark only the RBR-to-read-return path:

```text
A: 8250 RBR read / byte inserted
P: tty_flip_buffer_push() reached
Q: queue_work() called
Y: queue_work() returned true
N: queue_work() returned false
W: worker_thread() resumed
R: flush_to_ldisc() started
T: flush_to_ldisc() returned
C: n_tty_receive_buf_common() reached
D: newline recognized as canonical line end
E: reader wakeup issued
G: n_tty_read/read path returning data
```

Expected healthy path after `echo OK\n`:

```text
A P Q Y W R C D E T G
MARK-C: read returned
line=[echo OK]
OK
```

## How To Read The Next Result

```text
A only:
  serial8250 read happened, but byte was not pushed to tty buffering.

A P Q Y, no W:
  work was queued and accepted, but worker did not run.
  Suspect scheduler, interrupt return, preempt state, timer, or CPU state.

A P Q N:
  work was already pending/running.
  Need to see whether a prior W/R/T exists.

W R C but no D:
  n_tty is running, but newline/canonical handling is not reached.

D/E present but no G:
  wakeup happened, but the waiting read task did not return.
  Suspect scheduler, task wakeup, trap return, or userspace return.

G present but no MARK-C:
  kernel read path returned, but userspace/trap return is failing.
```

## Trace To Avoid For Now

Avoid broad always-on traces such as:

```text
all timer writes
all heartbeat PCs
all preempt_count add/sub
all UART RX/TX/IIR/LSR forever
```

Those logs hide the readiness point and can perturb timing. Use targeted traces around the current boundary.

## Current Files Touched In This Investigation

```text
src/uart_ns16550.sv
src/plic.sv
.gitignore
```

`fwuart-16550/` is ignored as reference code only.
