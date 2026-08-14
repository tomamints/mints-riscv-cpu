# ===============================================
# Makefile for SystemVerilog + Verilator project
# ===============================================

PROJECT     = core
TOP_MODULE  = core_top
TB_PROGRAM  = src/tb_verilator.cpp

# ツール
VERILATOR = verilator
PYTHON ?= python3
RISCV_PREFIX ?= riscv64-unknown-elf-
RISCV_GCC ?= $(RISCV_PREFIX)gcc
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_CFLAGS ?= -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles
DTC ?= dtc
DCACHE_LINE_COUNT ?= 128
DCACHE_STORE_BUFFER_DEPTH ?= 4
DCACHE_WRITE_BACK ?= 0
VERILATOR_DEFINES = -DSVCPU_DCACHE_LINE_COUNT=$(DCACHE_LINE_COUNT) -DSVCPU_DCACHE_STORE_BUFFER_DEPTH=$(DCACHE_STORE_BUFFER_DEPTH) -DSVCPU_DCACHE_WRITE_BACK=$(DCACHE_WRITE_BACK)

# Restrict environments may lack a working xargs, provide our shim.
export PATH := $(abspath tools):$(PATH)

# ディレクトリ
SRC_DIR   = src
OBJ_DIR   = obj_dir
INPUT_OBJ_DIR = obj_dir_input
TRACE_OBJ_DIR = obj_dir_trace
LOCKSTEP_OBJ_DIR = obj_dir_lockstep

# Whisper differential lockstep
WHISPER_DIR ?= whisper
WHISPER_BUILD_DIR ?= $(WHISPER_DIR)/build-Linux
WHISPER_LIB ?= $(WHISPER_BUILD_DIR)/librvcore.a
WHISPER_LOCKSTEP_DIR ?= tools/whisper_lockstep

LOCKSTEP_CPP_SRCS = \
	$(WHISPER_LOCKSTEP_DIR)/WhisperRef.cpp \
	$(WHISPER_DIR)/virtual_memory/VirtMem.cpp \
	$(WHISPER_DIR)/virtual_memory/Tlb.cpp \
	$(WHISPER_DIR)/pci/Pci.cpp \
	$(WHISPER_DIR)/pci/PciDev.cpp \
	$(WHISPER_DIR)/pci/virtio/Blk.cpp \
	$(WHISPER_DIR)/pci/virtio/Virtio.cpp

LOCKSTEP_CPPFLAGS = \
	-I$(abspath $(WHISPER_DIR)) \
	-I$(abspath $(WHISPER_DIR)/pci) \
	-I$(abspath $(WHISPER_DIR)/pci/virtio) \
	-I$(abspath $(WHISPER_LOCKSTEP_DIR))

LOCKSTEP_LDFLAGS = $(abspath $(WHISPER_LIB)) -pthread -lz

OPENSBI_ELF ?= build/external/opensbi/build/platform/generic/firmware/fw_jump.elf

# トップモジュール名
TOP       = core_top

# テストベンチ (C++)
TB        = $(SRC_DIR)/tb_verilator.cpp

# ソースリスト
FILELIST  = core.f
RTL_SRCS  = $(shell sed '/^\#/d;/^$$/d' $(FILELIST))

# 実行バイナリ名
SIM       = $(OBJ_DIR)/sim
INPUT_SIM = $(INPUT_OBJ_DIR)/sim
TRACE_SIM = $(TRACE_OBJ_DIR)/sim
LOCKSTEP_SIM = $(LOCKSTEP_OBJ_DIR)/sim
SIM_NAME = sim

# ラン用パラメータ
ROM ?= core/test/hex/sample_ecall.hex
RAM ?= $(ROM)
CYCLES ?= 20

# テスト用パラメータ
TEST_BUILD_DIR ?= build/test
C_TEST_BUILD_DIR ?= $(TEST_BUILD_DIR)/c_tests
BOOTROM ?= $(TEST_BUILD_DIR)/bootrom.hex
BOOTROM_OBJ = $(TEST_BUILD_DIR)/bootrom.o
BOOTROM_BIN = $(TEST_BUILD_DIR)/bootrom.bin
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
C_TEST_ELF = $(C_TEST_BUILD_DIR)/$(C_TEST).elf
C_TEST_BIN = $(C_TEST_BUILD_DIR)/$(C_TEST).bin
C_TEST_HEX = $(C_TEST_BUILD_DIR)/$(C_TEST).bin.hex
INPUT_TEXT ?= A
OS2_MIN_DIR ?= core/test/os2_min
OS2_MIN_CFLAGS ?= $(RISCV_CFLAGS) -std=gnu11 -fno-builtin
OS2_MIN_DEFS ?=
OS2_MIN_NAME ?= kernel
OS2_MIN_SRCS := $(wildcard $(OS2_MIN_DIR)/*.c) $(wildcard $(OS2_MIN_DIR)/*.S)
OS2_MIN_BUILD_DIR ?= build/os2_min
OS2_MIN_ELF = $(OS2_MIN_BUILD_DIR)/$(OS2_MIN_NAME).elf
OS2_MIN_BIN = $(OS2_MIN_BUILD_DIR)/$(OS2_MIN_NAME).bin
OS2_MIN_HEX = $(OS2_MIN_BUILD_DIR)/$(OS2_MIN_NAME).bin.hex
DTS ?= platform/riscv_cpu.dts
DTB ?= build/platform/riscv_cpu.dtb
LINUX_BOOTROM_ADDR ?= 0x80000000
LINUX_DTB_ADDR ?= 0x87f00000
LINUX_DTB_OFFSET ?= 0x7f00000
LINUX_RAM_SIZE ?= 0x8000000
LINUX_BOOTROM_SRC ?= platform/bootrom_linux.S
LINUX_BOOTROM_OBJ = build/platform/bootrom_linux.o
LINUX_BOOTROM_BIN = build/platform/bootrom_linux.bin
LINUX_BOOTROM_HEX = build/platform/bootrom_linux.hex
BOOTARGS_CHECK_SRC ?= platform/bootargs_check.S
BOOTARGS_CHECK_ELF = build/platform/bootargs_check.elf
BOOTARGS_CHECK_BIN = build/platform/bootargs_check.bin
BOOTARGS_CHECK_RAM_HEX = build/platform/bootargs_check_ram.hex
OPENSBI_PAYLOAD_SRCS = platform/opensbi_payload_entry.S platform/opensbi_payload.c
OPENSBI_PAYLOAD_LD ?= platform/opensbi_payload.ld
OPENSBI_PAYLOAD_ELF = build/platform/opensbi_payload.elf
OPENSBI_PAYLOAD_BIN = build/platform/opensbi_payload.bin
OPENSBI_BIN ?=
OPENSBI_RAM_HEX = build/platform/opensbi_ram.hex
OPENSBI_CYCLES ?= 200000000
LINUX_IMAGE_BIN ?=
LINUX_IMAGE_OFFSET ?= 0x200000

# =====================================================
# ルール
# =====================================================

.PHONY: all build build-input build-trace build-lockstep run run-lockstep run-opensbi-lockstep clean dtb linux-bootrom-build linux-ram-image test-linux-bootargs opensbi-payload-build test-opensbi-payload opensbi-ram-image run-opensbi run-opensbi-input test test-one test-suite test-rv32ui test-rv32um test-rv32ua test-rv32uc test-rv32mi test-rv32si test-rv64ui test-rv64um test-rv64ua test-rv64uc test-rv64mi test-rv64si test-smoke bootrom-build c-test c-test-build test-output test-input test-input-interactive test-dma test-uart test-uart-input test-uart-regs test-uart-tx-irq test-uart-tx-seip test-uart-rx-seip test-mswi test-mtime os2-min-build test-os2-min test-os2-min-input test-os2-min-strap test-os2-min-sv39 test-os2-min-pmp test-os2-min-user test-custom-all test-riscv-all trace-c-test trace-output trace-dma



# 2️⃣ シミュレーション実行
run: $(SIM)
	$(SIM) $(ROM) $(RAM) $(CYCLES)

$(SIM): $(RTL_SRCS) $(TB) $(FILELIST)
	$(MAKE) build

$(INPUT_SIM): $(RTL_SRCS) $(TB) $(FILELIST)
	$(MAKE) build-input

$(TRACE_SIM): $(RTL_SRCS) $(TB) $(FILELIST)
	$(MAKE) build-trace

$(LOCKSTEP_SIM): $(RTL_SRCS) $(TB) $(FILELIST) \
		$(WHISPER_LOCKSTEP_DIR)/WhisperRef.hpp \
		$(WHISPER_LOCKSTEP_DIR)/WhisperRef.cpp \
		$(WHISPER_LIB) \
		$(LOCKSTEP_CPP_SRCS)
	$(MAKE) build-lockstep

# Lockstep executable run.
# ROM/RAM are the same images consumed by the RTL simulator.
run-lockstep: $(LOCKSTEP_SIM)
	test -f "$(OPENSBI_ELF)" || (echo "Missing OPENSBI_ELF=$(OPENSBI_ELF)"; exit 1)
	test -f "$(DTB)" || (echo "Missing DTB=$(DTB)"; exit 1)
	WHISPER_OPENSBI_ELF="$(abspath $(OPENSBI_ELF))" \
	WHISPER_DTB="$(abspath $(DTB))" \
	DBG_ADDR="$(DBG_ADDR)" \
	$(LOCKSTEP_SIM) "$(ROM)" "$(RAM)" "$(CYCLES)" $(SIM_EXTRA_ARGS)

# 単体テスト実行
# 例: make test TEST=rv32ui-p-add
test test-one: $(SIM) bootrom-build
	$(PYTHON) $(TEST_RUNNER) $(SIM) $(TEST_DIR) $(TEST) --rom $(BOOTROM) --ram_base $(RAM_BASE) -o $(TEST_OUT) -t $(TEST_TIMEOUT) $(TEST_ARGS)

# riscv-tests の suite 実行
# 例: make test-suite SUITE=rv32ui-p
test-suite: $(SIM) bootrom-build
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

$(C_TEST_BUILD_DIR)/%.elf: core/test/%.c core/test/entry.S core/test/link.ld
	mkdir -p $(C_TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) -T core/test/link.ld core/test/entry.S $< -o $@

$(C_TEST_BUILD_DIR)/%.bin: $(C_TEST_BUILD_DIR)/%.elf
	$(RISCV_OBJCOPY) -O binary $< $@

$(C_TEST_BUILD_DIR)/%.bin.hex: $(C_TEST_BUILD_DIR)/%.bin
	$(PYTHON) core/test/bin2hex.py 8 $< > $@

bootrom-build:
	mkdir -p $(TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) -c core/test/bootrom.S -o $(BOOTROM_OBJ)
	$(RISCV_OBJCOPY) -O binary $(BOOTROM_OBJ) $(BOOTROM_BIN)
	$(PYTHON) core/test/bin2hex.py 8 $(BOOTROM_BIN) > $(BOOTROM)

c-test-build:
	mkdir -p $(C_TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) -T core/test/link.ld core/test/entry.S core/test/$(C_TEST).c -o $(C_TEST_ELF)
	$(RISCV_OBJCOPY) -O binary $(C_TEST_ELF) $(C_TEST_BIN)
	$(PYTHON) core/test/bin2hex.py 8 $(C_TEST_BIN) > $(C_TEST_HEX)

c-test: $(SIM) bootrom-build c-test-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

dtb: $(DTB)

$(DTB): $(DTS)
	mkdir -p $(dir $@)
	$(DTC) -I dts -O dtb -o $@ $<

linux-bootrom-build: $(LINUX_BOOTROM_HEX)

$(LINUX_BOOTROM_HEX): $(LINUX_BOOTROM_SRC)
	mkdir -p $(dir $@)
	$(RISCV_GCC) $(RISCV_CFLAGS) -c $< -o $(LINUX_BOOTROM_OBJ)
	$(RISCV_OBJCOPY) -O binary $(LINUX_BOOTROM_OBJ) $(LINUX_BOOTROM_BIN)
	$(PYTHON) core/test/bin2hex.py 8 $(LINUX_BOOTROM_BIN) > $@

$(BOOTARGS_CHECK_BIN): $(BOOTARGS_CHECK_SRC) core/test/link.ld
	mkdir -p $(dir $@)
	$(RISCV_GCC) $(RISCV_CFLAGS) -T core/test/link.ld $< -o $(BOOTARGS_CHECK_ELF)
	$(RISCV_OBJCOPY) -O binary $(BOOTARGS_CHECK_ELF) $@

linux-ram-image: $(BOOTARGS_CHECK_RAM_HEX)

$(BOOTARGS_CHECK_RAM_HEX): $(BOOTARGS_CHECK_BIN) $(DTB)
	$(PYTHON) tools/make_linux_ram_hex.py --payload $(BOOTARGS_CHECK_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) -o $@

test-linux-bootargs: CYCLES=20000
test-linux-bootargs: $(SIM) linux-bootrom-build linux-ram-image
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(LINUX_BOOTROM_HEX) $(BOOTARGS_CHECK_RAM_HEX) $(CYCLES)

opensbi-payload-build: $(OPENSBI_PAYLOAD_BIN)

$(OPENSBI_PAYLOAD_BIN): $(OPENSBI_PAYLOAD_SRCS) $(OPENSBI_PAYLOAD_LD)
	mkdir -p $(dir $@)
	$(RISCV_GCC) -march=rv64ima_zicsr -mabi=lp64 -mcmodel=medany -nostdlib -nostartfiles -ffreestanding -fno-builtin -T $(OPENSBI_PAYLOAD_LD) $(OPENSBI_PAYLOAD_SRCS) -o $(OPENSBI_PAYLOAD_ELF)
	$(RISCV_OBJCOPY) -O binary $(OPENSBI_PAYLOAD_ELF) $@

test-opensbi-payload: LINUX_IMAGE_BIN=$(OPENSBI_PAYLOAD_BIN)
test-opensbi-payload: opensbi-payload-build run-opensbi

opensbi-ram-image: $(DTB)
	test -n "$(OPENSBI_BIN)" || (echo "Set OPENSBI_BIN=/path/to/fw_jump.bin"; exit 1)
	if test -n "$(LINUX_IMAGE_BIN)"; then \
		$(PYTHON) tools/make_linux_ram_hex.py --payload $(OPENSBI_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) --blob $(LINUX_IMAGE_OFFSET):$(LINUX_IMAGE_BIN) -o $(OPENSBI_RAM_HEX); \
	else \
		$(PYTHON) tools/make_linux_ram_hex.py --payload $(OPENSBI_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) -o $(OPENSBI_RAM_HEX); \
	fi

run-opensbi: $(SIM) linux-bootrom-build opensbi-ram-image
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(LINUX_BOOTROM_HEX) $(OPENSBI_RAM_HEX) $(OPENSBI_CYCLES) $(SIM_EXTRA_ARGS)

run-opensbi-input: $(INPUT_SIM) linux-bootrom-build opensbi-ram-image
	DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(LINUX_BOOTROM_HEX) $(OPENSBI_RAM_HEX) $(OPENSBI_CYCLES) $(SIM_EXTRA_ARGS)

run-opensbi-lockstep: $(LOCKSTEP_SIM) linux-bootrom-build opensbi-ram-image
	test -f "$(OPENSBI_ELF)" || (echo "Missing OPENSBI_ELF=$(OPENSBI_ELF)"; exit 1)
	test -f "$(DTB)" || (echo "Missing DTB=$(DTB)"; exit 1)
	if test -n "$(LINUX_IMAGE_BIN)"; then \
		WHISPER_OPENSBI_ELF="$(abspath $(OPENSBI_ELF))" \
		WHISPER_DTB="$(abspath $(DTB))" \
		WHISPER_LINUX="$(abspath $(LINUX_IMAGE_BIN))" \
		DBG_ADDR="$(DBG_ADDR)" \
		$(LOCKSTEP_SIM) "$(LINUX_BOOTROM_HEX)" "$(OPENSBI_RAM_HEX)" "$(OPENSBI_CYCLES)" $(SIM_EXTRA_ARGS); \
	else \
		WHISPER_OPENSBI_ELF="$(abspath $(OPENSBI_ELF))" \
		WHISPER_DTB="$(abspath $(DTB))" \
		DBG_ADDR="$(DBG_ADDR)" \
		$(LOCKSTEP_SIM) "$(LINUX_BOOTROM_HEX)" "$(OPENSBI_RAM_HEX)" "$(OPENSBI_CYCLES)" $(SIM_EXTRA_ARGS); \
	fi

test-output: C_TEST=debug_output
test-output: CYCLES=10000
test-output: c-test

test-input: C_TEST=debug_input
test-input: CYCLES=10000
test-input: $(INPUT_SIM) bootrom-build c-test-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

test-input-interactive: C_TEST=debug_input
test-input-interactive: CYCLES=0
test-input-interactive: $(INPUT_SIM) bootrom-build c-test-build
	DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES) < /dev/tty

test-dma: C_TEST=debug_dma
test-dma: CYCLES=200000
test-dma: c-test

test-uart: C_TEST=uart_output
test-uart: CYCLES=20000
test-uart: c-test

test-uart-input: C_TEST=uart_input
test-uart-input: CYCLES=30000
test-uart-input: $(INPUT_SIM) bootrom-build c-test-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

test-uart-regs: C_TEST=uart_regs
test-uart-regs: CYCLES=30000
test-uart-regs: c-test

test-uart-tx-irq: C_TEST=uart_tx_irq
test-uart-tx-irq: CYCLES=300000
test-uart-tx-irq: c-test

test-uart-tx-seip: C_TEST=uart_tx_seip
test-uart-tx-seip: CYCLES=300000
test-uart-tx-seip: c-test

test-uart-rx-seip: C_TEST=uart_rx_seip
test-uart-rx-seip: CYCLES=300000
test-uart-rx-seip: $(INPUT_SIM) bootrom-build c-test-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

test-mswi: C_TEST=mswi
test-mswi: CYCLES=20000
test-mswi: c-test

test-mtime: C_TEST=mtime
test-mtime: CYCLES=1200000
test-mtime: c-test

os2-min-build:
	mkdir -p $(OS2_MIN_BUILD_DIR)
	$(RISCV_GCC) $(OS2_MIN_CFLAGS) $(OS2_MIN_DEFS) -T $(OS2_MIN_DIR)/kernel.ld $(OS2_MIN_SRCS) -o $(OS2_MIN_ELF)
	$(RISCV_OBJCOPY) -O binary $(OS2_MIN_ELF) $(OS2_MIN_BIN)
	$(PYTHON) core/test/bin2hex.py 8 $(OS2_MIN_BIN) > $(OS2_MIN_HEX)

test-os2-min: CYCLES=500000
test-os2-min: OS2_MIN_DEFS=-DOS2_MIN_NO_INPUT
test-os2-min: $(SIM) bootrom-build os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_HEX) $(CYCLES)

test-os2-min-input: CYCLES=70000
test-os2-min-input: OS2_MIN_DEFS=-DOS2_MIN_INPUT
test-os2-min-input: OS2_MIN_NAME=kernel_input
test-os2-min-input: $(INPUT_SIM) bootrom-build os2-min-build
	printf '%s' '$(INPUT_TEXT)' | DBG_ADDR=$(DBG_ADDR) $(INPUT_SIM) $(BOOTROM) $(OS2_MIN_HEX) $(CYCLES)

test-os2-min-strap: CYCLES=50000
test-os2-min-strap: OS2_MIN_DEFS=-DOS2_MIN_STRAP
test-os2-min-strap: OS2_MIN_NAME=kernel_strap
test-os2-min-strap: $(SIM) bootrom-build os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_HEX) $(CYCLES)

test-os2-min-sv39: CYCLES=8000000
test-os2-min-sv39: OS2_MIN_DEFS=-DOS2_MIN_SV39
test-os2-min-sv39: OS2_MIN_NAME=kernel_sv39
test-os2-min-sv39: $(SIM) bootrom-build os2-min-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(OS2_MIN_HEX) $(CYCLES)

test-os2-min-pmp:
	$(MAKE) test-os2-min OS2_MIN_DEFS=-DOS2_MIN_PMP OS2_MIN_NAME=kernel_pmp CYCLES=500000

test-os2-min-user:
	$(MAKE) test-os2-min OS2_MIN_DEFS=-DOS2_MIN_USER OS2_MIN_NAME=kernel_user CYCLES=120000

test-custom-all:
	$(MAKE) test-output
	$(MAKE) test-input
	$(MAKE) test-dma
	$(MAKE) test-uart
	$(MAKE) test-uart-regs
	$(MAKE) test-uart-tx-irq
	$(MAKE) test-uart-tx-seip
	$(MAKE) test-uart-rx-seip INPUT_TEXT=Z
	$(MAKE) test-mswi
	$(MAKE) test-mtime
	$(MAKE) test-os2-min
	$(MAKE) test-os2-min-input
	$(MAKE) test-os2-min-strap
	$(MAKE) test-os2-min-pmp
	$(MAKE) test-os2-min-user
	$(MAKE) test-os2-min-sv39

test-riscv-all:
	@failed=0; \
	for suite in rv32ui-p rv32um-p rv32ua-p rv32uc-p rv32mi-p rv32si-p rv64ui-p rv64um-p rv64ua-p rv64uc-p rv64mi-p rv64si-p; do \
		echo "===== $$suite ====="; \
		$(MAKE) test-suite SUITE=$$suite TEST_OUT=results-full || failed=1; \
	done; \
	exit $$failed

trace-c-test: $(TRACE_SIM) bootrom-build c-test-build
	DBG_ADDR=$(DBG_ADDR) $(TRACE_SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

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
	rm -rf $(LOCKSTEP_OBJ_DIR)
	rm -rf build
sim:
	verilator --cc $(VERILATOR_FLAGS) $(VERILATOR_DEFINES) -f $(FILELIST) --exe $(TB_PROGRAM) --top-module $(TOP_MODULE) --Mdir $(OBJ_DIR)
	make -C $(OBJ_DIR) -f V$(TOP_MODULE).mk
	mv $(OBJ_DIR)/V$(TOP_MODULE) $(OBJ_DIR)/$(SIM_NAME)

build:
	$(VERILATOR) --cc $(VERILATOR_DEFINES) -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(OBJ_DIR)
	make -C $(OBJ_DIR) -f V$(TOP).mk
	mv $(OBJ_DIR)/V$(TOP) $(OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Build complete. Run simulation with: make run"
	@echo "🧹 Cleaned build files."

build-input:
	$(VERILATOR) --cc $(VERILATOR_DEFINES) -DENABLE_DEBUG_INPUT -CFLAGS -DENABLE_DEBUG_INPUT -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(INPUT_OBJ_DIR)
	make -C $(INPUT_OBJ_DIR) -f V$(TOP).mk
	mv $(INPUT_OBJ_DIR)/V$(TOP) $(INPUT_OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Debug-input build complete. Run with: make test-input"

build-trace:
	$(VERILATOR) --trace --cc $(VERILATOR_DEFINES) -CFLAGS -DTRACE -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(TRACE_OBJ_DIR)
	make -C $(TRACE_OBJ_DIR) -f V$(TOP).mk
	mv $(TRACE_OBJ_DIR)/V$(TOP) $(TRACE_OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Trace build complete. Run with: make trace-output or make trace-dma"


build-lockstep:
	test -f "$(WHISPER_LIB)" || (echo "Missing Whisper library: $(WHISPER_LIB)"; exit 1)
	$(VERILATOR) --cc \
		$(VERILATOR_DEFINES) \
		-DSVCPU_WHISPER_LOCKSTEP \
		-CFLAGS "-DSVCPU_WHISPER_LOCKSTEP -std=c++20 $(LOCKSTEP_CPPFLAGS)" \
		-LDFLAGS "$(LOCKSTEP_LDFLAGS)" \
		-f $(FILELIST) \
		--exe $(TB) $(LOCKSTEP_CPP_SRCS) \
		--top-module $(TOP) \
		--Mdir $(LOCKSTEP_OBJ_DIR)
	$(MAKE) -C $(LOCKSTEP_OBJ_DIR) -f V$(TOP).mk \
		CFG_CXXFLAGS_STD="-std=gnu++20" \
		VM_CFLAGS="-Os"
	mv $(LOCKSTEP_OBJ_DIR)/V$(TOP) $(LOCKSTEP_OBJ_DIR)/$(SIM_NAME)
	@echo "✅ Lockstep build complete: $(LOCKSTEP_SIM)"
