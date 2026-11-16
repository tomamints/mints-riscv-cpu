# Architectural Scope and RVA23 Checklist

MiNTs-CPU does not currently claim RVA23 compliance. This checklist records the
boundaries of the current RV64IMAC Linux-capable implementation. Linux boot
is not evidence of complete profile compliance.

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


## Physical implementation

The documented DE0-CV build passes timing checks at 20 MHz and runs Linux with
an interactive UART shell. Physical timing closure and ISA/profile conformance
are separate properties; passing one does not prove the other. See
[current status](CURRENT_STATUS.md) and [test status](TEST_STATUS.md).
