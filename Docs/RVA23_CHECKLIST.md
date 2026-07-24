# RVA23 Direction Checklist

この文書は、Linux起動ロードマップとは別に、将来的にRVA23方向へ寄せるための確認項目を整理するものです。

`Docs/ROADMAP.md` は「Linuxを起動するための実装順」、この文書は「RVA23適合へ近づけるための棚卸し」として分けて扱います。

## 現在の位置づけ

現時点ではRVA23準拠を主張しません。

現在主張しやすい範囲は、RV64IMAC、CSR/trap/interruptの一部、ACLINT、最小SBI、PMP data/fetch access check、Sv39 data/fetch identity mapping、NS16550A互換UARTの最小polling TXのbring-upです。

## ISA / Extension

| Item | Status | Notes |
|---|---|---|
| RV64I | Pass current tests | `rv64ui-p` 54 / 54 pass。Linux/RVA23観点では追加確認が必要 |
| M | Pass basic tests | `rv64um-p` pass |
| A | Pass basic tests | `rv64ua-p` pass。LR/SC/AMOの詳細挙動は追加確認が必要 |
| C | Basic | `rv64uc-p` pass |
| Zicsr | Basic pass | `rv64si-p-csr` pass。未実装CSRやLinux要求CSRは追加確認が必要 |
| Zifencei | TODO | Linux/RVA23観点で要確認 |
| F/D | Not claimed | test pass/failに関わらず実装としては未主張 |
| Zb* | Not claimed | 専用decoder/unitとしては未整理 |

## Privileged Architecture

| Item | Status | Notes |
|---|---|---|
| M-mode trap | Basic pass | mswi/mtime、SBI dispatcher |
| S-mode transition | Pass | `mstatus.MPP=S`, `mepc`, `mret` |
| S-mode trap | Basic pass | S-mode ecall、timer、PMP load/store/fetch fault |
| U-mode transition | Basic pass | `sstatus.SPP=U`, `sepc=user_entry`, `sret` |
| U-mode syscall | Basic pass | `medeleg[8]`, U-mode `ecall -> stvec`、戻り値とexitの最小確認 |
| PMP | Basic pass | load/store R/W、fetch X、禁止storeのRAM副作用抑止を確認。MMIO副作用と部分重複の専用テストは未実装 |
| Sv39 | Basic / data+fetch | `sv39_ptw.sv` にPTWを分離。`satp.MODE=8`、3-level page walk、4KiB leaf PTE、identity mapping、`satp.PPN`切り替え、2MiB L1 / 1GiB L2 superpage、load/store/instruction page fault、SUM、MXR、A/D fault方式、内部fault detailを確認。PTW PTE read errorはaccess faultへ分類するが、bus側のerror生成は未実装。TLB/ASID、A/D自動更新は未実装 |
| Counters | Basic pass | `rv64mi-p-instret_overflow` pass。`mcounteren/scounteren` とLinux要求は追加確認が必要 |
| WFI | Partial | timer waitで使用。詳細仕様は未確認 |

## Platform / Linux

| Item | Status | Notes |
|---|---|---|
| ACLINT timer | Basic pass | MTIPをM-mode handlerで受け、STIPを注入 |
| UART | WIP | `0x10000000` にNS16550A互換の最小polling TXを追加。THR write、LSR THRE/TEMT、基本保持レジスタはあるが、RX/interrupt/PLIC連携は未実装 |
| PLIC | TODO | 外部割り込み向け |
| DTB | TODO | RAM/UART/ACLINT/PLICと一致させる |
| OpenSBI compatibility | TODO | 現在は独自最小SBI |

## 次に確認したい項目

- NS16550A UART register test、DTB node、Linux earlycon確認
- PTW memory error発生源、A/D bit hardware update要否
- `sfence.vma` のTLB flush接続
- `fence.i`, `wfi`, counter CSRの仕様差分
- Linux最小起動要件とRVA23要件の差分
