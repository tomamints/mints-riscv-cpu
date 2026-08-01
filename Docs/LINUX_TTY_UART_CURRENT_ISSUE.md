# Linux TTY/UART Bring-up Notes

Date: 2026-08-01

## Current Status

Linux now boots through OpenSBI, starts `/init`, and reaches the
`cmdloop-ttyS0` read loop:

```text
Run /init as init process
CMDLOOP-TTYS0
MARK-A: before loop
MARK-B: before read
```

With the latest RTL fixes, `echo OK` can reach:

```text
MARK-C: read returned
status=0
line=[echo OK]
OK
MARK-B: before read
```

This is the current baseline to preserve.

## Confirmed Working

The following path has been observed working:

```text
host input
-> UART RX FIFO/RBR
-> UART RX interrupt
-> PLIC source 10
-> S-mode external interrupt
-> Linux 8250 driver
-> tty flip buffer
-> kworker / flush_to_ldisc
-> n_tty canonical read
-> PID 1 read() return
-> cmdloop command handling
-> UART TX
```

The important visible userland sequence is:

```text
MARK-B: before read
echo OK
MARK-C: read returned
status=0
line=[echo OK]
OK
MARK-B: before read
```

## Root Causes Found

### 1. UART THRE pending was not cleared by IIR read

The UART TX interrupt model kept `tx_irq_pending` asserted after Linux read
`IIR = THRE`. This could leave the UART interrupt source high and repeatedly
re-trigger PLIC/SEIP.

Fix in `src/uart_ns16550.sv`:

```systemverilog
iir_reports_thre =
    iir_read &&
    !(rx_valid && ier[0]) &&
    tx_irq_pending &&
    ier[1];

if (iir_reports_thre) begin
    tx_irq_pending <= 1'b0;
end
```

Expected behavior:

```text
IIR reports THRE
-> tx_irq_pending clears
-> UART irq drops
-> PLIC complete sees source=0
```

### 2. `mip/sip.SEIP` was effectively writable

`MIP_WMASK` and `SIP_WMASK` previously allowed bit 9:

```text
0x222
```

Because `mip` read data included `external_seip`, a CSR read-modify-write could
copy an externally asserted SEIP into `mip_reg[9]`. After PLIC dropped `seip`,
the CPU could still see `sip.SEIP=1`, causing this invalid pattern:

```text
scause = supervisor external interrupt
PLIC claim = 0
PLIC seip = 0
```

Fix in `src/csrunit.sv`:

```systemverilog
MIP_WMASK = 0x22;
SIP_WMASK = 0x22;
```

and external/ACLINT-driven bits are excluded from `mip_reg` when composing
`mip`:

```systemverilog
mip = (mip_reg & ~0x0a88) | external_and_aclint_bits;
```

The externally driven bits are:

```text
MEIP bit 11
SEIP bit 9
MTIP bit 7
MSIP bit 3
```

### 3. `sret/mret` interrupt-enable restore needed cleanup

Trap return now restores the previous interrupt-enable bit and sets the
previous-enable bit back to 1:

```systemverilog
mret:
  MIE  <= MPIE
  MPIE <= 1

sret:
  SIE  <= SPIE
  SPIE <= 1
```

This is required by the privileged architecture. Later traces showed this was
not the final SEIP storm cause, but the fix is still correct.

## Trace State

No always-on Linux KTRACE should remain in the normal notrace image.

Removed call:

```c
svcpu_ktrace_irq('I');
```

from:

```text
build/external/linux/kernel/softirq.c
```

RTL traces remain plusarg-gated. They do not print unless explicitly enabled.
For normal confirmation, run without `SIM_EXTRA_ARGS=+TRACE...`.

Avoid broad trace while validating stability. It can hide readiness points and
perturb timing.

## Current Build Artifacts

Linux image rebuilt after removing `[I ...]` trace:

```text
build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs
```

RTL simulator rebuilt with:

```bash
make build-input
```

Run command:

```bash
make run-opensbi-input \
  OPENSBI_BIN=build/external/opensbi/build/platform/generic/firmware/fw_jump.bin \
  LINUX_IMAGE_BIN=build/external/linux-out/Image-linux-6.12-riscv64-busybox-cmdloop-ttyS0-notrace-initramfs \
  OPENSBI_CYCLES=0
```

## Next Checks

First validate the current baseline with trace disabled:

```text
echo OK
echo OK
echo hello
uname
cat /proc/interrupts
cat /proc/cpuinfo
```

Pass criteria:

```text
No [I ...] Linux KTRACE
No [UART ...] trace unless plusarg enabled
No [PLIC ...] trace unless plusarg enabled
Each command returns to MARK-B
No scause=9 / claim=0 storm
```

For `cmdloop-ttyS0`, a command pass looks like:

```text
MARK-C: read returned
status=0
line=[...]
...
MARK-B: before read
```

## If It Fails Again

Use only targeted trace.

### If output stops after TX

Enable only:

```text
+TRACE_TXUART
+TRACE_IRQ10PLIC
```

Check:

```text
IIR=c2 clears tx_irq_pending
UART irq drops
PLIC complete source=0
```

### If input reaches RBR but read does not return

Re-enable Linux KTRACE only around:

```text
tty_flip_buffer_push
queue_work return value
worker_thread
flush_to_ldisc
n_tty_receive_buf_common
n_tty_read return
```

Do not re-enable broad IRQ-exit or per-interrupt traces unless the failing
boundary again points there.

### If `scause=9` repeats with PLIC claim 0

Check CSR state:

```text
mip_reg[9]
external_seip
mip[9]
sip[9]
```

Expected after PLIC source drops:

```text
external_seip=0
mip_reg[9]=0
mip[9]=0
sip[9]=0
```

## Notes

The current problem was not a Linux design bug. Linux exposed assumptions that
the CPU/SoC model must satisfy:

```text
16550 THRE interrupt acknowledge semantics
PLIC level interrupt completion semantics
RISC-V mip/sip external interrupt read/write semantics
```

These are now the main areas fixed and should be protected by future tests.
