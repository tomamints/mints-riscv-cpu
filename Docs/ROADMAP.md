# Platform Scope

This page retains the former roadmap URL as a capability/status reference.
It lists established behavior and boundaries rather than development plans.

| Capability | Status |
|---|---|
| RV64IMAC, M/S/U, Sv39 and PMP Linux path | Implemented; exercised in simulator and board boot |
| Verilator Linux/BusyBox autotest | Recorded pass |
| Whisper architectural comparison | Historical pass through BusyBox autotest; not rerun for final board profile |
| DE0-CV physical Linux shell | Verified at 20 MHz, 64 MiB SDRAM, normal clocksource and 100 Hz periodic ticks |
| FPGA timing closure | All four corners pass for the documented 20 MHz artifact |
| JTAG RAM loader | Clears RAM, verifies all image words, releases CPU after successful verification |
| Standalone C application | MiNTs Life demo and checksum-validated elapsed-time workload run under board Linux |
| Board GPIO through Linux UIO | Input readings, LED register control and Life GPIO-mode integration verified; manual transitions/optical checks separate |
| Physical UART input/output | Verified at 115200 8N1 |
| Simulator branch prediction | PHT, BTB and RAS available; board profile disables prediction |
| Write-through D-cache | Selected baseline |
| Write-back D-cache | Experimental; outside validated board profile |
| Optional DMA | Simulator peripheral; not part of the validated board path |
| Persistent filesystem / SD-card Linux storage | Not part of the validated configuration |
| Linux graphical console / standalone keyboard interface | Not part of the validated configuration |
| Higher board frequency / 250 Hz kernel | Not established by current tests |
| Long-duration stability / general Linux distribution support | Not established by current tests |
| F/D, vectors, SMP/cache coherence, full RVA23 certification | Not claimed |

See [current status](CURRENT_STATUS.md), [test scope](TEST_STATUS.md) and
[documentation index](README.md) for the configurations and reproducible commands.
