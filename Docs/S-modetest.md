# Supervisor-mode Bring-up and Verification Checklist

S-modeのテスト項目を先にリスト化し、1項目ずつPASSを確認するためのチェックリストです。

ただし最初からLinuxを起動して確認するのではなく、

小さな単体テスト
→ S-mode用ミニOS
→ OpenSBI
→ Linux

の順番にします。

Linuxが起動しなかったとき、S-mode遷移、例外委譲、割り込み、MMUのどこが原因か分からなくなるためです。

まず今回のテスト範囲

最初はSv39を入れず、物理アドレスのまま動かします。

Phase 1: S-mode基本動作
  satp.MODE = Bare

Phase 2: U-mode・例外・割り込み

Phase 3: Sv39 MMU

Phase 4: Linux起動

S-modeは、単に現在の特権レベルを変えるだけではありません。Supervisor CSR、SRET、例外・割り込み委譲、仮想記憶などを含む実行環境です。RVA23S64もSupervisor-mode execution environmentとして定義され、Privileged Architecture 1.13を基礎としています。

## 現在の確認状況

| ID | Target | Status | 確認方法 |
|---|---|---|---|
| M2S-01 | `mstatus.MPP=S` でS-modeへ入る | PASS | `make test-os2-min` |
| M2S-02 | `mepc=supervisor_main` へ遷移する | PASS | `make test-os2-min` |
| M2S-03 | `mret` 後にS-mode codeが動く | PASS | `make test-os2-min` |
| SCSR-04 | S-modeから `sepc` をread/writeできる | PASS | `make test-os2-min-strap` |
| STRAP-ECALL-S-01 | `medeleg[9]=0` でS-mode `ecall` が `mtvec` へ入る | PASS | `make test-os2-min` |
| STRAP-ECALL-S-02 | `medeleg[9]=1` でS-mode `ecall` が `stvec` へ入る | PASS | `make test-os2-min-strap` |
| STRAP-10 | `sepc += 4` 後に `sret` で復帰する | PASS | `make test-os2-min-strap` |
| SBI-01 | S-mode `ecall` がM-mode SBI dispatcherへ到達する | PASS | `make test-os2-min` |
| SBI-02 | `a7/a6/a0` の受け渡し | PASS | `make test-os2-min` |
| SBI-03 | `a0=error`, `a1=value` 形式で復帰する | PASS | `make test-os2-min` |
| SBI-04 | `mepc += 4` 後にS-modeへ戻る | PASS | `make test-os2-min` |
| SBI-05 | console putchar | PASS | `make test-os2-min` |
| SBI-06 | console getchar | PASS | `make test-os2-min-input INPUT_TEXT=Z` |
| SBI-07 | TIME `set_timer` がACLINT `mtimecmp` を設定する | PASS | `make test-os2-min` |

## S-modeテスト一覧

### Phase 0：M-mode側の準備

Linux以前に、M-mode firmwareがS-modeへ正しく移れる必要があります。

ID	テスト	確認内容
M2S-01	mstatus.MPP = S	次のmret先がS-modeになる
M2S-02	mepc設定	指定したS-mode entryへ移動する
M2S-03	mret実行	S-modeコードが実行される
M2S-04	S-modeからM CSRアクセス	mstatusなどへのアクセスがillegal instructionになる
M2S-05	現在モード確認	S-modeでのみ許可された動作と禁止動作を確認する

最初のコードは、概念的にはこれだけです。

write_csr(mepc, supervisor_entry);

uint64_t mstatus = read_csr(mstatus);
mstatus &= ~MSTATUS_MPP_MASK;
mstatus |= MSTATUS_MPP_S;
write_csr(mstatus, mstatus);

asm volatile("mret");

そしてS-mode側でdebug MMIOへ文字を出せれば、最初のテストはPASSです。

ただし、S-modeからdebug MMIOを直接触る場合は、PMPまたは物理メモリアクセス権が適切に設定されている必要があります。

### Phase 1：Supervisor CSR
ID	テスト	期待結果
SCSR-01	sstatus read/write	実装対象ビットが正しく読み書きできる
SCSR-02	stvec read/write	trap handlerアドレスを保存できる
SCSR-03	sscratch read/write	任意の値を保持できる
SCSR-04	sepc read/write	trap復帰先を保持できる
SCSR-05	scause read	例外原因が正しい
SCSR-06	stval read	fault対象値が正しい
SCSR-07	sie/sip	割り込みenable/pendingが正しく見える
SCSR-08	satp Bare	MODE=0でアドレス変換なし
SCSR-09	非実装CSRアクセス	illegal instructionになる
SCSR-10	S-modeからM CSRアクセス	illegal instructionになる

特に、sstatusなどは独立した物理レジスタとは限りません。

例えばSIEやSPIEなどは、実質的にmstatusのSupervisor-visibleな部分として動作します。したがって、

S-modeがsstatus.SIEを書き換える
→ 対応する内部状態も変わる

ことを確認します。

### Phase 2：S-mode例外

ここが非常に重要です。

まずM-modeで例外委譲を設定します。

write_csr(medeleg,
    (1UL << CAUSE_ILLEGAL_INSTRUCTION) |
    (1UL << CAUSE_BREAKPOINT) |
    (1UL << CAUSE_ECALL_FROM_U_MODE)
);

その後、委譲した例外がS-modeの `stvec` へ到達すること、委譲しない例外がM-modeの `mtvec` へ到達することを分けて確認します。

ID	発生させる例外	確認する値
STRAP-ECALL-S-01	`medeleg[9]=0` でS-mode `ecall`	M-mode `mtvec` へtrapし、`mcause=9`
STRAP-ECALL-S-02	`medeleg[9]=1` でS-mode `ecall`	S-mode `stvec` へtrapし、`scause=9`
STRAP-02	illegal instruction	scause=2
STRAP-03	ebreak	scause=3
STRAP-04	misaligned load	scause=4
STRAP-05	misaligned store	scause=6
STRAP-06	access fault	対応するscause
STRAP-07	U-mode ecall	scause=8
STRAP-08	trap時のsepc	例外命令のPC
STRAP-09	trap時のstval	不正アドレスまたは命令情報
STRAP-10	sret	sepcの次の実行へ戻る

S-modeから実行された `ecall` は exception code 9 として扱われます。

`medeleg[9] = 0` の場合:

```text
S-mode ecall
  -> M-mode trap
  -> mtvec
  -> SBI firmware
```

SBI firmwareを呼び出す通常の構成では、この設定を使います。SBIはS-mode softwareからM-mode firmwareを呼び出すインターフェースなので、S-mode `ecall` をS-modeへ委譲してしまうとM-mode SBIへ到達しません。

`medeleg[9] = 1` の場合:

```text
S-mode ecall
  -> S-mode trap
  -> stvec
```

これはS-mode trap handler、`scause`、`sepc`、`sret` などの検証に使えます。したがって、S-mode `ecall` が必ずM-modeへ入るわけではなく、SBIとして利用する場合に意図的に `medeleg[9]` を0にします。

U-mode `ecall` は exception code 8 です。OS syscallとして使う場合は、通常 `medeleg[8]=1` としてS-modeの `stvec` へ入れます。

```text
U-mode ecall
  -> S-mode trap
  -> OS syscall handler
```

ここがSBIとOS syscallの境界です。

trap handlerの基本確認

S-mode trap entryでは最低限、次を保存します。

x1–x31
sepc
sstatus
scause
stval

そして処理後に、

csrw sepc, ...
sret

で戻ります。

ecallやebreakを処理して継続する場合は、一般にsepcを次の命令へ進めます。

write_csr(sepc, read_csr(sepc) + 4);

ただし圧縮命令を扱う場合、命令長が常に4バイトとは限らないので、将来的には命令長の判定が必要です。

### Phase 3：例外委譲

medelegの各ビットを変えて、到達先が変わることを独立にテストします。

ID	設定	期待結果
DELEG-01	対象ビット=0	M-modeのmtvecへ
DELEG-02	対象ビット=1	S-modeのstvecへ
DELEG-03	S-modeで発生した委譲対象例外	S-mode handlerへ
DELEG-04	委譲できない例外	M-mode handlerへ
DELEG-05	trap時の状態更新	SPP/SPIE/SIEが正しい
DELEG-06	sret後の状態復元	元の特権モードと割り込み状態へ戻る

このテストでは、M-modeとS-modeのhandlerで異なる文字をdebug MMIOへ出すと分かりやすいです。

M-mode trap → "M"
S-mode trap → "S"

### Phase 4：S-mode割り込み

最初はタイマー割り込み1種類だけで十分です。

現在のRTLでは、ACLINTの比較結果は `aclint.mtip -> mip.MTIP` に接続されています。一方で `mip.STIP` は0固定です。したがって、`mtime >= mtimecmp` は現状では machine timer interrupt になり、M-modeの `mtvec` へ入ります。

`mideleg` は既にpendingになっている割り込み原因をS-modeへ配送する仕組みであり、`MTIP` を `STIP` に変換する仕組みではありません。そのため、S-mode timer interruptを確認するには、方式Aとして M-mode firmware がMTIPを受けてSTIPをpendingにするRTL経路を追加するか、方式BとしてSstcを実装して `stimecmp` からSTIPを発生させる必要があります。

当面は方式Aで進めます。

```text
S-mode
  -> SBI set_timer(deadline)
M-mode firmware
  -> mtimecmp = deadline
time reached
  -> MTIP
  -> M-mode timer handler
  -> STIPをpendingにする
S-mode
  -> Supervisor Timer Interrupt
  -> stvec
```

ID	テスト	期待結果
SINT-00	SBI set_timer	`mtimecmp` が設定され、MTIPでM-mode trapへ入る
SINT-01	MTIP handler	M-mode handlerで `mtimecmp` を無効化または再設定する
SINT-02	STIP注入	M-modeからS-mode向けtimer pendingを立てられる
SINT-03	mideleg.STI=1	STIPがS-modeへ配送される
SINT-04	sie.STIE=1	Supervisor timer interruptを個別許可
SINT-05	sstatus.SIE=1	S-mode割り込みを全体許可
SINT-06	タイマー発火	scauseがinterrupt + cause 5
SINT-07	sepc保存	割り込まれた命令位置を保持
SINT-08	interrupt中のSIE/SPIE	自動更新が正しい
SINT-09	sret	元の処理へ復帰
SINT-10	再設定	次のタイマー割り込みが発生
SINT-11	SIE=0	割り込みを保留し、handlerへ入らない
SINT-12	外部割り込み	後でPLICと接続して確認

Privileged Architectureでは、Supervisor software、timer、external interruptはそれぞれcause 1、5、9として扱われます。

タイマー周りは、あなたの構成では次のどちらかになります。

方式A:
ACLINT/CLINTのmtimecmpをM-mode firmwareが操作し、MTIPをM-modeで受けてSTIPをS-modeへ注入する

方式B:
Sstcを実装してstimecmpをS-modeから操作

まずは方式Aでよいです。現在は `SBI set_timer -> mtimecmp -> MTIP -> M-mode trap` まで確認済みで、`STIP -> S-mode stvec` は未実装です。

### Phase 5：PMPとS-modeアクセス制御

これは忘れやすいですが、Linux起動には重要です。

ID	テスト	期待結果
PMP-01	許可されたRAM read	成功
PMP-02	許可されたRAM write	成功
PMP-03	許可されたRAM execute	成功
PMP-04	禁止領域read	access fault
PMP-05	禁止領域write	access fault
PMP-06	禁止領域execute	instruction access fault
PMP-07	debug MMIO許可	S-modeから利用可能、またはSBI経由
PMP-08	firmware領域保護	S-modeから書き換え不可

最初のbring-upでは、RAMと必要なMMIO領域をS-modeへ広く許可しても構いません。

ただし最終的には、

OpenSBI領域 → M-modeのみ
Linux RAM   → S/U-mode利用可能
MMIO        → 必要な領域だけ許可

に分ける方がよいです。

### Phase 6：U-modeへの遷移

Linuxを動かすならU-modeも必要です。

ID	テスト	期待結果
S2U-01	sstatus.SPP=U	sret後にU-modeへ
S2U-02	sepc=user_entry	U-mode entryへ移動
S2U-03	U-mode通常命令	正常実行
S2U-04	U-modeからS CSRアクセス	illegal instruction
S2U-05	U-mode ecall	S-mode trapへ
S2U-06	syscall引数	a0–a7を正しく取得
S2U-07	syscall戻り値	a0などで返却
S2U-08	sretでU-mode復帰	ecall後の次命令から再開
S2U-09	U-mode禁止領域アクセス	S-mode page/access fault
S2U-10	複数syscall	trap frameが壊れない

ここまで動けば、小さな自作OSとして、

U-mode application
    ↓ ecall
S-mode syscall handler
    ↓
debug MMIO output

を実現できます。

### Phase 7：Sv39テスト

ここからMMUです。S-mode基本動作とは分離してください。

最低限のSv39テスト
ID	テスト	期待結果
VM-01	satp.MODE=Sv39	ページング有効化
VM-02	identity mapping	仮想アドレス=物理アドレスで実行
VM-03	4 KiB leaf mapping	正しい物理ページへ変換
VM-04	read permission	R=1ページを読める
VM-05	write permission	W=1ページへ書ける
VM-06	execute permission	X=1ページを実行できる
VM-07	invalid PTE	page fault
VM-08	R=0 load	load page fault
VM-09	W=0 store	store page fault
VM-10	X=0 fetch	instruction page fault
VM-11	U bit	U/Sアクセス制御
VM-12	A bit	accessed bitの扱い
VM-13	D bit	dirty bitの扱い
VM-14	sfence.vma	TLBを正しく無効化
VM-15	ASID変更	アドレス空間を切り替えられる
VM-16	canonical address	不正Sv39アドレスでfault
VM-17	SUM	S-modeからUページへのdata access制御
VM-18	MXR	execute-onlyページのread制御
VM-19	misaligned superpage	page fault
VM-20	page table walk fault	正しいcauseとstval

SATPはSupervisor Address Translation and Protectionを設定し、Sv39などのページベース仮想記憶モードを選択します。SFENCE.VMAはページテーブル変更後のアドレス変換キャッシュ同期に使います。

ただし、最初は以下だけで十分です。

VM-01 satp設定
VM-02 identity mapping
VM-03 4 KiB mapping
VM-07 invalid PTE fault
VM-08/09/10 R/W/X fault
VM-14 sfence.vma
最初に実装するテスト10個

いきなり全部は多いので、次の順番を推奨します。

01. M-modeからmretでS-modeへ移行
02. S-modeからdebug MMIOで文字を出力
03. S-modeでsstatus/stvec/sscratchを読み書き
04. S-modeからM-mode CSRへアクセスしてillegal instruction
05. S-modeのillegal instructionをstvecで受ける
06. scause/sepc/stvalを確認
07. sretで元のS-mode処理へ復帰
08. S-mode ecallをM-modeで受ける
09. U-modeへ移行
10. U-mode ecallをS-modeで受ける

これを通してから、

11. Supervisor timer interrupt
12. PMP
13. Sv39 identity mapping
14. Page fault
15. OpenSBI
16. Linux

へ進みます。

## SBIテスト

SBI testでは、S-mode `ecall` をM-mode firmwareへ届けるために `medeleg[9]=0` にします。

ID	テスト	期待結果
SBI-01	`medeleg[9]=0` でS-mode `ecall`	M-mode SBI dispatcherへ到達
SBI-02	`a7/a6/a0-a5` の受け渡し	Extension ID、Function ID、引数が正しい
SBI-03	SBIから復帰	`a0=error`、`a1=value`
SBI-04	ECALL後の復帰PC	`mepc += 4` してS-modeへ戻る
SBI-05	console putchar	debug MMIOへ1文字出力できる

最初はSBI v0.1のlegacy consoleではなく、学習用の最小dispatcherとして作って構いません。ただし呼び出し規約はSBIに寄せて、戻り値は `struct sbiret { long error; long value; }` の形にします。

## テストコードの構成

1つの巨大なプログラムにするより、各テストを独立させる方がデバッグしやすいです。

tests/
├── smode/
│   ├── 01_enter_smode.S
│   ├── 02_scsr.S
│   ├── 03_illegal_instruction.S
│   ├── 04_exception_delegation.S
│   ├── 05_sret.S
│   ├── 06_smode_ecall.S
│   ├── 07_timer_interrupt.S
│   ├── 08_enter_umode.S
│   └── 09_umode_ecall.S
└── sv39/
    ├── 01_identity_map.S
    ├── 02_page_permissions.S
    ├── 03_page_fault.S
    └── 04_sfence_vma.S

各テストは最終的に、

PASS: STRAP-02

または、

FAIL: expected scause=2, actual=...

をdebug MMIOへ出す形がよいです。

## テストベンチ側で確認するもの

現在はVerilator C++ testbench、debug MMIO、waveformで確認します。将来的にはcocotbやdifferential testingを追加すると強くなります。

現在:

- Verilator C++ testbench
- debug MMIO
- waveform

将来:

- cocotb
- Spikeなどとのdifferential testing
- FPGA UART

ソフトウェアのdebug MMIO出力だけでなく、テストベンチから内部状態も確認すると強くなります。

assert dut.privilege_mode.value == SUPERVISOR
assert dut.csr_scause.value == 2
assert dut.csr_sepc.value == expected_pc
assert dut.csr_stval.value == expected_stval

さらにSpikeなどの参照モデルと、以下を比較できます。

PC
命令
特権モード
書き込みレジスタ
CSR更新
例外cause
メモリアクセス

公式のRISC-V Architectural Certification TestsはISAへの適合性確認用ですが、公式README自身も「これだけで完全なverificationになるわけではなく、追加検証が必要」と明記しています。したがって、既存テストを通すことと、今回のようなS-mode単体テストを自分で用意することの両方が必要です。

最初の明確なマイルストーンは、これです。

M-modeからS-modeへ移行し、S-mode例外をstvecで処理してSRETで正常復帰できる。

ここまで動けば、次にU-mode syscall、タイマー割り込み、Sv39へ進めます。
