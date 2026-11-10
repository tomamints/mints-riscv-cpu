# ===============================================
# Makefile for SystemVerilog + Verilator project
# ===============================================

PROJECT     = core
TOP_MODULE  = core_top
TB_PROGRAM  = tb/tb_verilator.cpp

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
DCACHE_DATA_RAM_STYLE ?= 0
RAM_LATENCY_SHIM ?= 0
ICACHE_LINE_COUNT ?= 128
ICACHE_DATA_RAM_STYLE ?= 0
BP_PHT_ENTRIES ?= 128
BP_BTB_ENTRIES ?= 32
BP_RAS_ENTRIES ?= 8
VERILATOR_DEFINES = -DSVCPU_DCACHE_LINE_COUNT=$(DCACHE_LINE_COUNT) -DSVCPU_DCACHE_STORE_BUFFER_DEPTH=$(DCACHE_STORE_BUFFER_DEPTH) -DSVCPU_DCACHE_WRITE_BACK=$(DCACHE_WRITE_BACK) -DSVCPU_DCACHE_DATA_RAM_STYLE=$(DCACHE_DATA_RAM_STYLE)
VERILATOR_DEFINES += -DSVCPU_ICACHE_LINE_COUNT=$(ICACHE_LINE_COUNT) -DSVCPU_ICACHE_DATA_RAM_STYLE=$(ICACHE_DATA_RAM_STYLE)
VERILATOR_DEFINES += -DSVCPU_BP_PHT_ENTRIES=$(BP_PHT_ENTRIES) -DSVCPU_BP_BTB_ENTRIES=$(BP_BTB_ENTRIES) -DSVCPU_BP_RAS_ENTRIES=$(BP_RAS_ENTRIES)
# TLB entries per translation unit (performance only). The define is added only
# for a non-default size so the default build record is unchanged.
TLB_ENTRIES ?= 8
ifneq ($(TLB_ENTRIES),8)
VERILATOR_DEFINES += -DSVCPU_TLB_ENTRIES=$(TLB_ENTRIES)
endif
# Carry-chain PMP compares on the critical checkers (same results; board timing).
PMP_CARRY_COMPARE ?= 0
ifneq ($(PMP_CARRY_COMPARE),0)
VERILATOR_DEFINES += -DSVCPU_PMP_CARRY_COMPARE=$(PMP_CARRY_COMPARE)
endif
# Simulation-only RAM latency shim (C3 M1). The source is added only when enabled,
# so the default file list and build are unchanged.
ifeq ($(RAM_LATENCY_SHIM),1)
VERILATOR_DEFINES += -DSVCPU_RAM_LATENCY_SHIM tb/model/membus_latency_shim.sv
endif

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
TB        = tb/tb_verilator.cpp

# ソースリスト
FILELIST  = core.f
RTL_SRCS  = $(shell sed '/^\#/d;/^$$/d' $(FILELIST))
# Simulation RAM backend: `sim` (default, src/memory.sv) or `sdram_model`
# (adapter -> bridge64 -> native16 @20 MHz -> clock-sampled SDRAM model with a
# through-adapter preloader). The sdram_model file list includes core.f.
RAM_BACKEND ?= sim
SDRAM_BACKEND_SRCS = rtl/bus/membus_sdram_adapter.sv fpga/de0-cv/sdram/rtl/sdram_bridge64.sv \
	fpga/de0-cv/sdram/rtl/sdram_native16.sv tb/model/sdram_cycle_model16.sv tb/model/sdram_preloader.sv
ifeq ($(RAM_BACKEND),sdram_model)
VERILATOR_DEFINES += -DSVCPU_RAM_SDRAM_MODEL
FILELIST = tb/model/sdram_backend.f
RTL_SRCS = $(shell sed '/^\#/d;/^$$/d' core.f) $(SDRAM_BACKEND_SRCS)
else ifneq ($(RAM_BACKEND),sim)
$(error RAM_BACKEND must be sim or sdram_model)
endif

# Physical 8N1 UART backend for the common 20 MHz board clock. Default simulation
# keeps its byte/DPI backend. External RX is held idle by the C++ harness.
PHYSICAL_UART ?= 0
ifeq ($(PHYSICAL_UART),1)
UART_PHYSICAL_SRCS = rtl/peripheral/uart16550_regs.sv fpga/de0-cv/rtl/uart_baud_gen.sv \
	fpga/de0-cv/rtl/uart_tx.sv fpga/de0-cv/rtl/uart_rx.sv fpga/de0-cv/rtl/uart_phy.sv \
	rtl/peripheral/uart16550_serial.sv
VERILATOR_DEFINES += -DSVCPU_PHYSICAL_UART -CFLAGS -DENABLE_PHYSICAL_UART $(UART_PHYSICAL_SRCS)
RTL_SRCS += $(UART_PHYSICAL_SRCS)
else ifneq ($(PHYSICAL_UART),0)
$(error PHYSICAL_UART must be 0 or 1)
endif

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
# C test sources and the shared harness (bootrom/entry/link script).
C_TEST_SRC_DIR ?= core/test
C_TEST_COMMON_DIR ?= tb/sw/common
BOOTROM_SRC ?= $(C_TEST_COMMON_DIR)/bootrom.S
C_TEST_ENTRY ?= $(C_TEST_COMMON_DIR)/entry.S
C_TEST_LD ?= $(C_TEST_COMMON_DIR)/link.ld
C_TEST_HARNESS_DEFS ?= -DDEBUG_MMIO_ADDR=$(DBG_ADDR) -DRAM_BASE_ADDR=$(RAM_BASE)
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
# Platform capacity profile (C3 M3c):
#   legacy  - default simulation platform, unchanged: 128 MiB RAM image, DTB
#             source 0x87f00000, outputs in build/platform/;
#   de0cv64 - DE0-CV board profile: 64 MiB RAM (bounded decode, full-range
#             normal/cacheable memory), 20 MHz timebase DTS, DTB source
#             0x83f00000, outputs in build/platform/de0cv64/ so the artifacts of
#             the two profiles never mix.
PLATFORM_PROFILE ?= legacy
LINUX_BOOTROM_ADDR ?= 0x80000000
# Offset of OpenSBI's FDT copy (generic FW_JUMP_FDT_ADDR - FW_TEXT_START; the
# built fw_jump.elf has fw_next_arg1 = 0x82200000). Reserved in the RAM image.
LINUX_FDT_RELOC_OFFSET ?= 0x2200000
LINUX_FDT_RELOC_RESERVE ?= 0x10000
ifeq ($(PLATFORM_PROFILE),legacy)
PLATFORM_BUILD_DIR = build/platform
DTS ?= platform/riscv_cpu.dts
LINUX_DTB_ADDR ?= 0x87f00000
LINUX_DTB_OFFSET ?= 0x7f00000
LINUX_RAM_SIZE ?= 0x8000000
else ifeq ($(PLATFORM_PROFILE),de0cv64)
PLATFORM_BUILD_DIR = build/platform/de0cv64
DTS ?= platform/riscv_cpu_de0cv64.dts
LINUX_DTB_ADDR ?= 0x83f00000
LINUX_DTB_OFFSET ?= 0x3f00000
LINUX_RAM_SIZE ?= 0x4000000
# The board has exactly 64 MiB; checked at parse time, so it applies to every
# target (simulator builds included), not only to the image targets.
ifneq ($(shell printf %d $(LINUX_RAM_SIZE)),67108864)
$(error PLATFORM_PROFILE=de0cv64 requires LINUX_RAM_SIZE=0x4000000, got $(LINUX_RAM_SIZE))
endif
# RTL capacity, as a decimal value (no shell quoting of an SV literal).
VERILATOR_DEFINES += -DSVCPU_RAM_SIZE_BYTES=$(shell printf %d $(LINUX_RAM_SIZE))
# Profile-isolated simulator directories (a command-line OBJ_DIR still wins;
# the sim.cfg guard below rejects reusing a directory built for another config).
OBJ_DIR = obj_dir_de0cv64
INPUT_OBJ_DIR = obj_dir_input_de0cv64
TRACE_OBJ_DIR = obj_dir_trace_de0cv64
LOCKSTEP_OBJ_DIR = obj_dir_lockstep_de0cv64
else
$(error PLATFORM_PROFILE must be legacy or de0cv64)
endif
DTB ?= $(PLATFORM_BUILD_DIR)/riscv_cpu.dtb
LINUX_BOOTROM_SRC ?= platform/bootrom_linux.S
LINUX_BOOTROM_OBJ = $(PLATFORM_BUILD_DIR)/bootrom_linux.o
LINUX_BOOTROM_BIN = $(PLATFORM_BUILD_DIR)/bootrom_linux.bin
LINUX_BOOTROM_HEX = $(PLATFORM_BUILD_DIR)/bootrom_linux.hex
# Records the profile values; artifacts depend on it, so changing any value
# (for example LINUX_DTB_ADDR=...) rebuilds the bootrom, DTB and RAM images.
PLATFORM_CFG = $(PLATFORM_BUILD_DIR)/platform.cfg
BOOTARGS_CHECK_SRC ?= platform/bootargs_check.S
BOOTARGS_CHECK_ELF = $(PLATFORM_BUILD_DIR)/bootargs_check.elf
BOOTARGS_CHECK_BIN = $(PLATFORM_BUILD_DIR)/bootargs_check.bin
BOOTARGS_CHECK_RAM_HEX = $(PLATFORM_BUILD_DIR)/bootargs_check_ram.hex
OPENSBI_PAYLOAD_SRCS = platform/opensbi_payload_entry.S platform/opensbi_payload.c
OPENSBI_PAYLOAD_LD ?= platform/opensbi_payload.ld
OPENSBI_PAYLOAD_ELF = build/platform/opensbi_payload.elf
OPENSBI_PAYLOAD_BIN = build/platform/opensbi_payload.bin
OPENSBI_BIN ?=
OPENSBI_RAM_HEX = $(PLATFORM_BUILD_DIR)/opensbi_ram.hex
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

# The sim.cfg guards (order-only) run before any use of an existing simulator.
$(SIM): $(RTL_SRCS) $(TB) $(FILELIST) | check-sim-cfg
	$(MAKE) build

$(INPUT_SIM): $(RTL_SRCS) $(TB) $(FILELIST) | check-input-sim-cfg
	$(MAKE) build-input

$(TRACE_SIM): $(RTL_SRCS) $(TB) $(FILELIST) | check-trace-sim-cfg
	$(MAKE) build-trace

$(LOCKSTEP_SIM): $(RTL_SRCS) $(TB) $(FILELIST) \
		$(WHISPER_LOCKSTEP_DIR)/WhisperRef.hpp \
		$(WHISPER_LOCKSTEP_DIR)/WhisperRef.cpp \
		$(WHISPER_LIB) \
		$(LOCKSTEP_CPP_SRCS) | check-lockstep-sim-cfg
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

$(C_TEST_BUILD_DIR)/%.elf: $(C_TEST_SRC_DIR)/%.c $(C_TEST_ENTRY) $(C_TEST_LD)
	mkdir -p $(C_TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) $(C_TEST_HARNESS_DEFS) -T $(C_TEST_LD) $(C_TEST_ENTRY) $< -o $@

$(C_TEST_BUILD_DIR)/%.bin: $(C_TEST_BUILD_DIR)/%.elf
	$(RISCV_OBJCOPY) -O binary $< $@

$(C_TEST_BUILD_DIR)/%.bin.hex: $(C_TEST_BUILD_DIR)/%.bin
	$(PYTHON) tools/bin2hex.py 8 $< > $@

bootrom-build:
	mkdir -p $(TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) $(C_TEST_HARNESS_DEFS) -c $(BOOTROM_SRC) -o $(BOOTROM_OBJ)
	$(RISCV_OBJCOPY) -O binary $(BOOTROM_OBJ) $(BOOTROM_BIN)
	$(PYTHON) tools/bin2hex.py 8 $(BOOTROM_BIN) > $(BOOTROM)

c-test-build:
	mkdir -p $(C_TEST_BUILD_DIR)
	$(RISCV_GCC) $(RISCV_CFLAGS) $(C_TEST_HARNESS_DEFS) -T $(C_TEST_LD) $(C_TEST_ENTRY) $(C_TEST_SRC_DIR)/$(C_TEST).c -o $(C_TEST_ELF)
	$(RISCV_OBJCOPY) -O binary $(C_TEST_ELF) $(C_TEST_BIN)
	$(PYTHON) tools/bin2hex.py 8 $(C_TEST_BIN) > $(C_TEST_HEX)

c-test: $(SIM) bootrom-build c-test-build
	DBG_ADDR=$(DBG_ADDR) $(SIM) $(BOOTROM) $(C_TEST_HEX) $(CYCLES)

dtb: $(DTB)

# ---- platform profile consistency: fail instead of building inconsistent images ----
.PHONY: check-platform-profile FORCE
check-platform-profile:
	@test $$(( $(LINUX_DTB_ADDR) )) -eq $$(( $(LINUX_BOOTROM_ADDR) + $(LINUX_DTB_OFFSET) )) || \
	  { echo "LINUX_DTB_ADDR $(LINUX_DTB_ADDR) != LINUX_BOOTROM_ADDR + LINUX_DTB_OFFSET"; exit 1; }
	@test $$(( $(LINUX_DTB_OFFSET) + 0x10000 )) -le $$(( $(LINUX_RAM_SIZE) )) || \
	  { echo "DTB source offset $(LINUX_DTB_OFFSET) leaves no room in LINUX_RAM_SIZE $(LINUX_RAM_SIZE)"; exit 1; }
	@if test "$(PLATFORM_PROFILE)" = de0cv64; then \
	  test $$(( $(LINUX_RAM_SIZE) )) -eq $$(( 0x4000000 )) || { echo "de0cv64 requires LINUX_RAM_SIZE 0x4000000"; exit 1; }; \
	fi

# The profile record is rewritten only when its content changes. It covers every
# value that affects the bootrom, bootargs check, DTB and RAM images.
PLATFORM_CFG_TEXT = PLATFORM_PROFILE=$(PLATFORM_PROFILE) DTS=$(DTS) DTC=$(DTC) \
	LINUX_BOOTROM_ADDR=$(LINUX_BOOTROM_ADDR) LINUX_DTB_ADDR=$(LINUX_DTB_ADDR) \
	LINUX_DTB_OFFSET=$(LINUX_DTB_OFFSET) LINUX_RAM_SIZE=$(LINUX_RAM_SIZE) \
	LINUX_FDT_RELOC_OFFSET=$(LINUX_FDT_RELOC_OFFSET) LINUX_FDT_RELOC_RESERVE=$(LINUX_FDT_RELOC_RESERVE) \
	LINUX_IMAGE_OFFSET=$(LINUX_IMAGE_OFFSET) RISCV_GCC=$(RISCV_GCC) RISCV_CFLAGS=$(RISCV_CFLAGS)

# Simulator build record: every value that changes the generated model. A sim
# directory built for one configuration is never reused for another: the guard
# fails with both records instead of silently reusing (or rebuilding over) it.
# Existing binaries without records must be rebuilt explicitly in a separate
# directory; their configuration cannot be inferred from the requested flags.
SIM_CFG_TEXT = PLATFORM_PROFILE=$(PLATFORM_PROFILE) RAM_BACKEND=$(RAM_BACKEND) \
	FILELIST=$(FILELIST) DEFINES=$(VERILATOR_DEFINES) FLAGS=$(VERILATOR_FLAGS)
define sim_cfg_guard
	@mkdir -p $(1)
	@if test -f $(1)/sim.cfg; then \
	  echo '$(SIM_CFG_TEXT) VARIANT=$(2)' | cmp -s - $(1)/sim.cfg || \
	  { echo "$(1) was built for: $$(cat $(1)/sim.cfg)"; echo "requested: $(SIM_CFG_TEXT) VARIANT=$(2)"; \
	    echo "use a different OBJ_DIR (profiles default to isolated directories)"; exit 1; }; \
	else \
	  if test -e $(1)/sim; then \
	    echo "$(1)/sim has no verified build record; use a new directory and build explicitly"; exit 1; \
	  fi; \
	fi
endef
# Explicit build targets (re)generate the model and then rewrite the record.
define sim_cfg_record
	@echo '$(SIM_CFG_TEXT) VARIANT=$(2)' > $(1)/sim.cfg
endef
.PHONY: check-sim-cfg check-input-sim-cfg check-trace-sim-cfg check-lockstep-sim-cfg
check-sim-cfg:
	$(call sim_cfg_guard,$(OBJ_DIR),plain)
check-input-sim-cfg:
	$(call sim_cfg_guard,$(INPUT_OBJ_DIR),input)
check-trace-sim-cfg:
	$(call sim_cfg_guard,$(TRACE_OBJ_DIR),trace)
check-lockstep-sim-cfg:
	$(call sim_cfg_guard,$(LOCKSTEP_OBJ_DIR),lockstep)
$(PLATFORM_CFG): FORCE
	@mkdir -p $(dir $@)
	@echo '$(PLATFORM_CFG_TEXT)' | cmp -s - $@ || echo '$(PLATFORM_CFG_TEXT)' > $@

$(DTB): $(DTS) $(PLATFORM_CFG) | check-platform-profile
	mkdir -p $(dir $@)
	$(DTC) -I dts -O dtb -o $@ $<

linux-bootrom-build: $(LINUX_BOOTROM_HEX)

$(LINUX_BOOTROM_HEX): $(LINUX_BOOTROM_SRC) tools/bin2hex.py $(PLATFORM_CFG) | check-platform-profile
	mkdir -p $(dir $@)
	$(RISCV_GCC) $(RISCV_CFLAGS) -DLINUX_DTB_ADDR=$(LINUX_DTB_ADDR) -c $< -o $(LINUX_BOOTROM_OBJ)
	$(RISCV_OBJCOPY) -O binary $(LINUX_BOOTROM_OBJ) $(LINUX_BOOTROM_BIN)
	$(PYTHON) tools/bin2hex.py 8 $(LINUX_BOOTROM_BIN) > $@

$(BOOTARGS_CHECK_BIN): $(BOOTARGS_CHECK_SRC) $(C_TEST_LD) $(PLATFORM_CFG) | check-platform-profile
	mkdir -p $(dir $@)
	$(RISCV_GCC) $(RISCV_CFLAGS) -DLINUX_DTB_ADDR=$(LINUX_DTB_ADDR) -T $(C_TEST_LD) $< -o $(BOOTARGS_CHECK_ELF)
	$(RISCV_OBJCOPY) -O binary $(BOOTARGS_CHECK_ELF) $@

linux-ram-image: $(BOOTARGS_CHECK_RAM_HEX)

$(BOOTARGS_CHECK_RAM_HEX): $(BOOTARGS_CHECK_BIN) $(DTB) $(PLATFORM_CFG)
	$(PYTHON) tools/make_linux_ram_hex.py --payload $(BOOTARGS_CHECK_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) --reserve $(LINUX_FDT_RELOC_OFFSET):$(LINUX_FDT_RELOC_RESERVE):opensbi-fdt-copy -o $@

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

opensbi-ram-image: $(DTB) $(PLATFORM_CFG) | check-platform-profile
	test -n "$(OPENSBI_BIN)" || (echo "Set OPENSBI_BIN=/path/to/fw_jump.bin"; exit 1)
	if test -n "$(LINUX_IMAGE_BIN)"; then \
		$(PYTHON) tools/make_linux_ram_hex.py --payload $(OPENSBI_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) --reserve $(LINUX_FDT_RELOC_OFFSET):$(LINUX_FDT_RELOC_RESERVE):opensbi-fdt-copy --blob $(LINUX_IMAGE_OFFSET):$(LINUX_IMAGE_BIN) -o $(OPENSBI_RAM_HEX); \
	else \
		$(PYTHON) tools/make_linux_ram_hex.py --payload $(OPENSBI_BIN) --dtb $(DTB) --dtb-offset $(LINUX_DTB_OFFSET) --size $(LINUX_RAM_SIZE) --reserve $(LINUX_FDT_RELOC_OFFSET):$(LINUX_FDT_RELOC_RESERVE):opensbi-fdt-copy -o $(OPENSBI_RAM_HEX); \
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
	$(PYTHON) tools/bin2hex.py 8 $(OS2_MIN_BIN) > $(OS2_MIN_HEX)

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
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) --cc $(VERILATOR_DEFINES) -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(OBJ_DIR)
	make -C $(OBJ_DIR) -f V$(TOP).mk
	mv $(OBJ_DIR)/V$(TOP) $(OBJ_DIR)/$(SIM_NAME)
	$(call sim_cfg_record,$(OBJ_DIR),plain)
	@echo "✅ Build complete. Run simulation with: make run"
	@echo "🧹 Cleaned build files."

build-input:
	mkdir -p $(INPUT_OBJ_DIR)
	$(VERILATOR) --cc $(VERILATOR_DEFINES) -DENABLE_DEBUG_INPUT -CFLAGS -DENABLE_DEBUG_INPUT -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(INPUT_OBJ_DIR)
	make -C $(INPUT_OBJ_DIR) -f V$(TOP).mk
	mv $(INPUT_OBJ_DIR)/V$(TOP) $(INPUT_OBJ_DIR)/$(SIM_NAME)
	$(call sim_cfg_record,$(INPUT_OBJ_DIR),input)
	@echo "✅ Debug-input build complete. Run with: make test-input"

build-trace:
	mkdir -p $(TRACE_OBJ_DIR)
	$(VERILATOR) --trace --cc $(VERILATOR_DEFINES) -CFLAGS -DTRACE -f $(FILELIST) --exe $(TB) --top-module $(TOP) --Mdir $(TRACE_OBJ_DIR)
	make -C $(TRACE_OBJ_DIR) -f V$(TOP).mk
	mv $(TRACE_OBJ_DIR)/V$(TOP) $(TRACE_OBJ_DIR)/$(SIM_NAME)
	$(call sim_cfg_record,$(TRACE_OBJ_DIR),trace)
	@echo "✅ Trace build complete. Run with: make trace-output or make trace-dma"


build-lockstep:
	test -f "$(WHISPER_LIB)" || (echo "Missing Whisper library: $(WHISPER_LIB)"; exit 1)
	$(VERILATOR) --cc \
		$(VERILATOR_DEFINES) \
		-DSVCPU_WHISPER_LOCKSTEP \
		-CFLAGS "-DSVCPU_WHISPER_LOCKSTEP -std=c++20 $(LOCKSTEP_CPPFLAGS)" \
		-LDFLAGS "$(LOCKSTEP_LDFLAGS)" \
		-f $(FILELIST) \
		--exe $(abspath $(TB)) $(abspath $(LOCKSTEP_CPP_SRCS)) \
		--top-module $(TOP) \
		--Mdir $(LOCKSTEP_OBJ_DIR)
	$(MAKE) -C $(LOCKSTEP_OBJ_DIR) -f V$(TOP).mk \
		CFG_CXXFLAGS_STD="-std=gnu++20" \
		VM_CFLAGS="-Os"
	mv $(LOCKSTEP_OBJ_DIR)/V$(TOP) $(LOCKSTEP_OBJ_DIR)/$(SIM_NAME)
	$(call sim_cfg_record,$(LOCKSTEP_OBJ_DIR),lockstep)
	@echo "✅ Lockstep build complete: $(LOCKSTEP_SIM)"
