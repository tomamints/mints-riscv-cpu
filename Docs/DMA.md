# DMA Engine

Last updated: 2026-08-14

This document describes the optional MMIO DMA engine in MiNTs-CPU.

The DMA engine is an experimental SoC peripheral. It is not part of the CPU
pipeline and is not required for the current Linux/BusyBox validation path.

## Scope

Implemented:

- MMIO register read/write interface
- RAM master read/write path
- RAM-to-RAM copy in 8-byte units
- `busy`, `done`, and `err` status bits
- 8-byte alignment checks
- immediate completion for `LEN == 0`
- CPU-priority RAM arbitration

Limitations:

- no DMA interrupt output yet
- no byte/halfword/word copy mode yet
- no out-of-range RAM address error reporting yet
- one channel only
- not part of the main Linux performance baseline

## Register Map

Base address:

```text
0x50000000
```

| Offset | Name | Access | Description |
|---:|---|---|---|
| `0x00` | `CTRL` | RW | start, clear-done, irq-enable |
| `0x08` | `STATUS` | RO | busy, done, error |
| `0x10` | `SRC` | RW | source RAM address |
| `0x18` | `DST` | RW | destination RAM address |
| `0x20` | `LEN` | RW | transfer length in bytes |

`CTRL` bits:

| Bit | Name | Description |
|---:|---|---|
| 0 | `start` | write `1` to start a transfer |
| 1 | `clear_done` | write `1` to clear `done` and `err` |
| 2 | `irq_en` | stored, but interrupt output is not implemented |
| 63:3 | reserved | reads as zero |

`STATUS` bits:

| Bit | Name | Description |
|---:|---|---|
| 0 | `busy` | transfer in progress |
| 1 | `done` | transfer completed |
| 2 | `err` | alignment error |
| 63:3 | reserved | reads as zero |

## Operation

On `CTRL.start`, the DMA engine captures `SRC`, `DST`, and `LEN`.

The engine then repeats:

```text
read  8 bytes from SRC
write 8 bytes to DST
advance SRC/DST
decrement remaining length
```

All addresses and lengths must be 8-byte aligned. Misaligned `SRC`, `DST`, or
`LEN` sets `STATUS.err`.

## Example

```c
#define DMA_BASE   0x50000000UL
#define DMA_CTRL   (*(volatile unsigned long *)(DMA_BASE + 0x00))
#define DMA_STATUS (*(volatile unsigned long *)(DMA_BASE + 0x08))
#define DMA_SRC    (*(volatile unsigned long *)(DMA_BASE + 0x10))
#define DMA_DST    (*(volatile unsigned long *)(DMA_BASE + 0x18))
#define DMA_LEN    (*(volatile unsigned long *)(DMA_BASE + 0x20))

DMA_SRC = source_address;
DMA_DST = destination_address;
DMA_LEN = byte_length;
DMA_CTRL = 1;

while (DMA_STATUS & 1) {
    /* wait */
}
```

## Future Work

- range checking against the RAM window
- DMA interrupt output through PLIC
- byte-mask support for non-8-byte transfers
- dedicated DMA regression tests
