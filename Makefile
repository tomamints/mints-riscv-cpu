# ===============================================
# Makefile for SystemVerilog + Verilator project
# ===============================================

PROJECT     = core
TOP_MODULE  = core_top
TB_PROGRAM  = src/tb_verilator.cpp

# ツール
VERILATOR = verilator
PYTHON ?= python3
RISCV_PREFIX ?= /Users/shiraitouma/riscv/bin/riscv64-unknown-elf-
RISCV_GCC ?= $(RISCV_PREFIX)gcc
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_CFLAGS ?= -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles

# Restrict environments may lack a working xargs, provide our shim.
export PATH := $(abspath tools):$(PATH)

# ディレクトリ
SRC_DIR   = src
OBJ_DIR   = obj_dir
INPUT_OBJ_DIR = obj_dir_input
TRACE_OBJ_DIR = obj_dir_trace

# トップモジュール名
TOP       = core_top

# テストベンチ (C++)
TB        = $(SRC_DIR)/tb_verilator.cpp

# ソースリスト
FILELIST  = core.f

# 実行バイナリ名
SIM       = $(OBJ_DIR)/sim
INPUT_SIM = $(INPUT_OBJ_DIR)/sim
TRACE_SIM = $(TRACE_OBJ_DIR)/sim
SIM_NAME = sim

# ラン用パラメータ
ROM ?= core/test/sample_ecall.hex
RAM ?= $(ROM)
CYCLES ?= 20

# テスト用パラメータ
BOOTROM ?= core/test/bootrom.hex
TEST_DIR ?= core/test/share
TEST ?= rv32ui-p-simple
SUITE ?= rv32ui-p
TEST_OUT ?= results
TEST_TIMEOUT ?= 10
RAM_BASE ?= 0x80000000
TEST_ARGS ?=
TEST_RUNNER ?= tools/run_riscv_tests.py
DBG_ADDR ?= 0x40000000
C_TEST ?= debug_output
INPUT_TEXT ?= A
OS2_MIN_DIR ?= core/test/os2_min
OS2_MIN_CFLAGS ?= $(RISCV_CFLAGS) -std=gnu11 -fno-builtin
OS2_MIN_DEFS ?=
OS2_MIN_NAME ?= kernel
OS2_MIN_SRCS := $(wildcard $(OS2_MIN_DIR)/*.c) $(wildcard $(OS2_MIN_DIR)/*.S)

# =====================================================
# ルール
# =====================================================

.PHONY: all build build-input build-trace run clean test test-one test-suite test-rv32ui test-rv32um test-rv32ua test-rv32uc test-rv32mi test-rv32si test-rv64ui test-rv64um test-rv64ua test-rv64uc test-rv64mi test-rv64si test-smoke c-test c-test-build test-output test-input test-input-interactive test-dma test-mswi test-mtime os2-min-build test-os2-min test-os2-min-input test-os2-min-trap test-os2-min-smode test-os2-min-strap test-os2-min-sbi trace-c-test trace-output trace-dma



# 2️⃣ シミュレーション実行
run: $(SIM)
	$(SIM) $(ROM) $(RAM) $(CYCLES)

$(SIM):
	$(MAKE) build

$(INPUT_SIM):
	$(MAKE) build-input

$(TRACE_SIM):
	$(MAKE) build-trace

# 単体テスト実行
# 例: make test TEST=rv32ui-p-add
test test-one: $(SIM)
	$(PYTHON) $(TEST_RUNNER) $(SIM) $(TEST_DIR) $(TEST) --rom $(BOOTROM) --ram_base $(RAM_BASE) -o $(TEST_OUT) -t $(TEST_TIMEOUT) $(TEST_ARGS)

# riscv-tests の suite 実行
# 例: make test-suite SUITE=rv32ui-p
test-suite: $(SIM)
	$(PYTHON) $(TEST_RUNNER) $(SIM) $(TEST_DIR) $(SUITE) --rom $(BOOTROM) --ram_base $(RAM_BASE) -o $(TEST_OUT)/$(SUITE) -t $(TEST_TIMEOUT) $(TEST_ARGS)

test-rv32ui: SUITE=rv32ui-p
test-rv32ui: test-suite

test-rv32um: SUITE=rv32um-p
test-rv32um: test-suite

test-rv32ua: SUITE=rv32ua-p
test-rv32ua: test-suite

test-rv32uc: SUITE=rv32uc-p
test-rv32uc: test-suite

test-rv32mi: SUITE=rv32mi-p
test-rv32mi: test-suite

test-rv32si: SUITE=rv32si-p
test-rv32si: test-suite

test-rv64ui: SUITE=rv64ui-p
test-rv64ui: test-suite

test-rv64um: SUITE=rv64um-p
test-rv64um: test-suite

test-rv64ua: SUITE=rv64ua-p
test-rv64ua: test-suite

test-rv64uc: SUITE=rv64uc-p
test-rv64uc: test-suite

test-rv64mi: SUITE=rv64mi-p
test-rv64mi: test-suite

test-rv64si: SUITE=rv64si-p
test-rv64si: test-suite

test-smoke: TEST=rv32ui-p-simple
test-smoke: test-one

core/test/%.elf: core/test/%.c core/test/entry.S core/test/link.ld
	$(RISCV_GCC) $(RISCV_CFLAGS) -T core/test/link.ld core/test/entry.S $< -o $@

core/test/%.bin: core/test/%.elf
	$(RISCV_OBJCOPY) -O binary $< $@

core/test/%.bin.hex: core/test/%.bin
	$(PYTHON) core/test/bin2hex.py 8 $< > $@

c-test-build:
	$(RISCV_GCC) $(RISCV_CFLAGS) -T core/test/link.ld core/test/entry.S core/test/$(C_TEST).c -o core/test/$(C_TEST).elf
	$(RISCV_OBJCOPY) -O binary core/test/$(C_TEST).elf core/test/$(C_TEST).bin
	$(PYTHON) core/test/bin2hex.py 8 core/test/$(C_TEST).bin > core/test/$(C_TEST).bin.hex

c-test: $(SIM) c-test-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) core/test/$(C_TEST).bin.hex $(CYCLES)

test-output: C_TEST=debug_output
test-output: CYCLES=10000
test-output: c-test

test-input: C_TEST=debug_input
test-input: CYCLES=10000
test-input: $(INPUT_SIM) c-test-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) core/test/$(C_TEST).bin.hex $(CYCLES)

test-input-interactive: C_TEST=debug_input
test-input-interactive: CYCLES=0
test-input-interactive: $(INPUT_SIM) c-test-build
	DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) core/test/$(C_TEST).bin.hex $(CYCLES) < /dev/tty

test-dma: C_TEST=debug_dma
test-dma: CYCLES=200000
test-dma: c-test

test-mswi: C_TEST=mswi
test-mswi: CYCLES=20000
test-mswi: c-test

test-mtime: C_TEST=mtime
test-mtime: CYCLES=1200000
test-mtime: c-test

os2-min-build:
	$(RISCV_GCC) $(OS2_MIN_CFLAGS) $(OS2_MIN_DEFS) -T $(OS2_MIN_DIR)/kernel.ld $(OS2_MIN_SRCS) -o $(OS2_MIN_DIR)/$(OS2_MIN_NAME).elf
	$(RISCV_OBJCOPY) -O binary $(OS2_MIN_DIR)/$(OS2_MIN_NAME).elf $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin
	$(PYTHON) core/test/bin2hex.py 8 $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin > $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex

test-os2-min: CYCLES=50000
test-os2-min: $(SIM) os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

test-os2-min-input: CYCLES=50000
test-os2-min-input: OS2_MIN_DEFS=-DOS2_MIN_ECHO
test-os2-min-input: OS2_MIN_NAME=kernel_echo
test-os2-min-input: $(INPUT_SIM) os2-min-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

test-os2-min-trap: CYCLES=50000
test-os2-min-trap: OS2_MIN_DEFS=-DOS2_MIN_TRAP
test-os2-min-trap: OS2_MIN_NAME=kernel_trap
test-os2-min-trap: $(SIM) os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

test-os2-min-smode: CYCLES=50000
test-os2-min-smode: OS2_MIN_DEFS=-DOS2_MIN_SMODE
test-os2-min-smode: OS2_MIN_NAME=kernel_smode
test-os2-min-smode: $(SIM) os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

test-os2-min-strap: CYCLES=50000
test-os2-min-strap: OS2_MIN_DEFS=-DOS2_MIN_STRAP
test-os2-min-strap: OS2_MIN_NAME=kernel_strap
test-os2-min-strap: $(SIM) os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

test-os2-min-sbi: CYCLES=50000
test-os2-min-sbi: OS2_MIN_DEFS=-DOS2_MIN_SBI
test-os2-min-sbi: OS2_MIN_NAME=kernel_sbi
test-os2-min-sbi: $(SIM) os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_DIR)/$(OS2_MIN_NAME).bin.hex $(CYCLES)

trace-c-test: $(TRACE_SIM) c-test-build
	DBG_ADDR=$(DBG_ADDR) $(TRACE_SIM) $(BOOTROM) core/test/$(C_TEST).bin.hex $(CYCLES)

trace-output: C_TEST=debug_output
trace-output: CYCLES=20000
trace-output: trace-c-test

trace-dma: C_TEST=debug_dma
trace-dma: CYCLES=200000
trace-dma: trace-c-test

# 3️⃣ クリーンアップ
clean:
	rm -rf $(OBJ_DIR)
	rm -rf $(INPUT_OBJ_DIR)
	rm -rf $(TRACE_OBJ_DIR)
sim:
	verilator --cc $(VERILATOR_FLAGS) -f $(FILELIST) --exe $(TB_PROGRAM) --top-module $(TOP_MODULE) --Mdir $(OBJ_DIR)
	make -C $(OBJ_DIR) -f V$(TOP_MODULE).mk
	mv $(OBJ_DIR)/V$(TOP_MODULE) $(OBJ_DIR)/$(SIM_NAME)

build:
	$(VERILATOR) --cc -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(OBJ_DIR)
	make -C $(OBJ_DIR) -f V$(TOP).mk
	mv $(OBJ_DIR)/V$(TOP) $(OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Build complete. Run simulation with: make run"
	@echo "🧹 Cleaned build files."

build-input:
	$(VERILATOR) --cc -DENABLE_DEBUG_INPUT -CFLAGS -DENABLE_DEBUG_INPUT -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(INPUT_OBJ_DIR)
	make -C $(INPUT_OBJ_DIR) -f V$(TOP).mk
	mv $(INPUT_OBJ_DIR)/V$(TOP) $(INPUT_OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Debug-input build complete. Run with: make test-input"

build-trace:
	$(VERILATOR) --trace --cc -CFLAGS -DTRACE -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(TRACE_OBJ_DIR)
	make -C $(TRACE_OBJ_DIR) -f V$(TOP).mk
	mv $(TRACE_OBJ_DIR)/V$(TOP) $(TRACE_OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Trace build complete. Run with: make trace-output or make trace-dma"
