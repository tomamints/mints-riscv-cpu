# RVA23 Direction Checklist

この文書は、Linux起動ロードマップとは別に、将来的にRVA23方向へ寄せるための確認項目を整理するものです。

`Docs/ROADMAP.md` は「Linuxを起動するための実装順」、この文書は「RVA23適合へ近づけるための棚卸し」として分けて扱います。

## 現在の位置づけ

現時点ではRVA23準拠を主張しません。

現在主張しやすい範囲は、RV64IMAC、CSR/trap/interruptの一部、ACLINT、最小SBI、PMP data/fetch access check、Sv39 data/fetch identity mappingのbring-upです。

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
| S-mode trap | Basic pass | S-mode ecall、timer、PMP load/store/fetch fault |
| U-mode transition | Basic pass | `sstatus.SPP=U`, `sepc=user_entry`, `sret` |
| U-mode syscall | Basic pass | `medeleg[8]`, U-mode `ecall -> stvec`、戻り値とexitの最小確認 |
| PMP | Basic pass | load/store R/W、fetch X、禁止storeのRAM副作用抑止を確認。MMIO副作用と部分重複の専用テストは未実装 |
| Sv39 | Basic / data+fetch | `sv39_ptw.sv` にPTWを分離。`satp.MODE=8`、3-level page walk、4KiB leaf PTE、identity mapping、2MiB L1 / 1GiB L2 superpage、load page fault、instruction page fault、SUM、MXR、A/D fault方式、内部fault detailを確認。PTW PTE read errorはaccess faultへ分類するが、bus側のerror生成は未実装。TLB/ASID、A/D自動更新は未実装 |
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

- Sv39 store permission page faultの専用テスト強化
- PTW memory error発生源、MPRV/effective privilege、A/D bit hardware update要否
- `sfence.vma` のTLB flush接続
- `fence.i`, `wfi`, counter CSRの仕様差分
- Linux最小起動要件とRVA23要件の差分
