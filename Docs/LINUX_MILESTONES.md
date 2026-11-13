# Linux Validation Scope

“Linux boots” and “an interactive system works” are separate checks. MiNTs-CPU
has recorded both simulator autotest success and physical-board shell operation.

| Target | Observed completion condition |
|---|---|
| Verilator | OpenSBI → Linux → `/init` autotest → `BUSYBOX-TEST-PASS` |
| Historical Whisper lockstep | Architectural comparison continues through the BusyBox autotest pass marker |
| Physical DE0-CV | OpenSBI → Linux → interactive BusyBox shell, followed by continued UART commands and load/idle checks |

The Linux path exercises S-mode, Sv39, U-mode programs, basic syscalls,
procfs/sysfs/devtmpfs/tmpfs, timer interrupts and console operation. The board
also exercises physical SDRAM, UART receive interrupts and JTAG image loading.

For the final 20 MHz board profile, `riscv_clocksource` remains active with
100 Hz periodic ticks. Commands, file operations, a CPU loop, 1 MiB of zero-data
processing, sleep and recovery after 30 seconds of idle time passed. A short
host-versus-Linux elapsed-time comparison was close to unity. This is not
long-duration stability or precision clock calibration.

The historical lockstep result is not a new validation of every subsequent
RTL change or of the FPGA electrical interface. ISA tests have a known
`rv64mi-p-breakpoint` failure in the reported 110/111 checkpoint.

Persistent storage, general distribution compatibility, networking, graphics,
SMP/coherence, floating point, full RVA23 compliance, 250 Hz board operation
and a higher board frequency are outside the established validation scope.

See [test status](TEST_STATUS.md), [Linux setup](LINUX_SETUP.md) and the
[physical board guide](../fpga/de0-cv/soc/README.md) for commands and conditions.
