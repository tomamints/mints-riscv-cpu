# RVA23 Direction Checklist

この文書は、Linux起動ロードマップとは別に、将来的にRVA23方向へ寄せるための確認項目を整理するものです。

`Docs/ROADMAP.md` は「Linuxを起動するための実装順」、この文書は「RVA23適合へ近づけるための棚卸し」として分けて扱います。

## 現在の位置づけ

現時点ではRVA23準拠を主張しません。

現在主張しやすい範囲は、RV64IMAC、CSR/trap/interruptの一部、ACLINT、最小SBI、PMP data access checkのbring-upです。

## ISA / Extension

| Item | Status | Notes |
|---|---|---|
| RV64I | Partial | `rv64ui-p` は一部failあり |
| M | Pass basic tests | `rv64um-p` pass |
| A | Pass basic tests | `rv64ua-p` pass。LR/SC/AMOの詳細挙動は追加確認が必要 |
| C | Basic | `rv64uc-p` pass |
| Zicsr | Partial | CSR privilege checkを実装中 |
| Zifencei | TODO | Linux/RVA23観点で要確認 |
| F/D | Not claimed | test pass/failに関わらず実装としては未主張 |
| Zb* | Not claimed | 専用decoder/unitとしては未整理 |

## Privileged Architecture

| Item | Status | Notes |
|---|---|---|
| M-mode trap | Basic pass | mswi/mtime、SBI dispatcher |
| S-mode transition | Pass | `mstatus.MPP=S`, `mepc`, `mret` |
| S-mode trap | Basic pass | S-mode ecall、timer、PMP load/store fault |
| U-mode transition | TODO | 次フェーズ |
| U-mode syscall | TODO | `medeleg[8]`, U-mode `ecall -> stvec` |
| PMP | Data basic pass | load/store R/W。fetch/Xは未実装 |
| Sv39 | TODO | Bareのみ |
| Counters | Partial | `mcounteren/scounteren` の追加確認が必要 |
| WFI | Partial | timer waitで使用。詳細仕様は未確認 |

## Platform / Linux

| Item | Status | Notes |
|---|---|---|
| ACLINT timer | Basic pass | MTIPをM-mode handlerで受け、STIPを注入 |
| UART | TODO | debug MMIOはLinux標準デバイスではない |
| PLIC | TODO | 外部割り込み向け |
| DTB | TODO | RAM/UART/ACLINT/PLICと一致させる |
| OpenSBI compatibility | TODO | 現在は独自最小SBI |

## 次に確認したい項目

- PMP fault時にmemory/MMIO requestが出ないこと
- PMP instruction fetch / X permission
- U-modeへ `sret` で遷移できること
- U-mode `ecall` をS-mode syscall handlerで受けること
- `fence.i`, `wfi`, counter CSRの仕様差分
- Linux最小起動要件とRVA23要件の差分
