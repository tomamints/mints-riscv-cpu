# RVA23 Direction Checklist

Last updated: 2026-08-14

MiNTs-CPU does not currently claim RVA23 compliance. This checklist records the
gap between the current RV64IMAC Linux-capable implementation and a future
profile-oriented target.

## Current Claimed Scope

| Area | Status |
|---|---|
| RV64I | implemented and tested in current regression scope |
| M | implemented |
| A | implemented for current Linux/lockstep path |
| C | implemented |
| Zicsr | implemented for current privilege/Linux path |
| M/S/U privilege | implemented for current Linux path |
| Sv39 | implemented with ITLB, DTLB, and PTW |
| PMP | 8-entry implementation |
| ACLINT | MSWI and MTIMER |
| PLIC | minimal PLIC-compatible controller |
| UART | minimal NS16550A-compatible device |

## Not Claimed

| Area | Notes |
|---|---|
| F/D floating point | not implemented |
| vector extension | not implemented |
| full RVA23 profile | not claimed |
| SMP/cache coherence | not implemented |
| complete architectural certification | not claimed |
| FPGA timing closure | not completed |

## Future Checks

- run a profile-oriented architectural test suite
- document exact supported extensions and CSRs
- audit trap/interrupt behavior against the privileged specification
- audit memory-ordering behavior beyond the current Linux path
- add FPGA timing and resource reports
