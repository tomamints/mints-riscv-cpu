ROOT_DIR ?= $(CURDIR)
WHISPER_DIR ?= $(ROOT_DIR)/whisper
BUILD_DIR ?= $(ROOT_DIR)/build/whisper-lockstep
SRC_DIR ?= $(ROOT_DIR)/tools/whisper_lockstep

CXX ?= c++
CXXFLAGS ?= -std=c++20 -O2 -g

CPPFLAGS += -I$(WHISPER_DIR)
CPPFLAGS += -I$(WHISPER_DIR)/pci
CPPFLAGS += -I$(WHISPER_DIR)/pci/virtio
CPPFLAGS += -I$(SRC_DIR)

WHISPER_LIB := $(WHISPER_DIR)/build-Linux/librvcore.a

TARGET := $(BUILD_DIR)/whisper_api_smoke

LOCAL_OBJECTS := \
	$(BUILD_DIR)/WhisperRef.o \
	$(BUILD_DIR)/whisper_api_smoke.o

VIRTMEM_SRC := $(WHISPER_DIR)/virtual_memory/VirtMem.cpp
VIRTMEM_OBJ := $(BUILD_DIR)/whisper-VirtMem.o

TLB_SRC := $(WHISPER_DIR)/virtual_memory/Tlb.cpp
TLB_OBJ := $(BUILD_DIR)/whisper-Tlb.o

PCI_OBJECTS := \
	$(BUILD_DIR)/pci-Pci.o \
	$(BUILD_DIR)/pci-PciDev.o

VIRTIO_OBJECTS := \
	$(BUILD_DIR)/pci-virtio-Blk.o \
	$(BUILD_DIR)/pci-virtio-Virtio.o

ALL_OBJECTS := \
	$(LOCAL_OBJECTS) \
	$(VIRTMEM_OBJ) \
	$(TLB_OBJ) \
	$(PCI_OBJECTS) \
	$(VIRTIO_OBJECTS)

LDLIBS += -pthread
LDLIBS += -lz
LDLIBS += $(EXTRA_LDLIBS)

.PHONY: whisper-api-smoke
.PHONY: clean-whisper-api-smoke
.PHONY: show-whisper-sources

whisper-api-smoke: $(TARGET)
	@echo "Built $(TARGET)"

show-whisper-sources:
	@echo "Whisper sources:"
	@echo "  $(VIRTMEM_SRC)"
	@echo "  $(TLB_SRC)"
	@echo "  $(WHISPER_DIR)/pci/Pci.cpp"
	@echo "  $(WHISPER_DIR)/pci/PciDev.cpp"
	@echo "  $(WHISPER_DIR)/pci/virtio/Blk.cpp"
	@echo "  $(WHISPER_DIR)/pci/virtio/Virtio.cpp"

$(TARGET): $(ALL_OBJECTS) $(WHISPER_LIB)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) \
		$(ALL_OBJECTS) \
		-Wl,--start-group \
		$(WHISPER_LIB) \
		-Wl,--end-group \
		$(LDLIBS) \
		-o $@

$(BUILD_DIR)/WhisperRef.o: $(SRC_DIR)/WhisperRef.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/whisper_api_smoke.o: $(SRC_DIR)/whisper_api_smoke.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(VIRTMEM_OBJ): $(VIRTMEM_SRC)
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(TLB_OBJ): $(TLB_SRC)
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/pci-Pci.o: $(WHISPER_DIR)/pci/Pci.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/pci-PciDev.o: $(WHISPER_DIR)/pci/PciDev.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/pci-virtio-Blk.o: $(WHISPER_DIR)/pci/virtio/Blk.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/pci-virtio-Virtio.o: $(WHISPER_DIR)/pci/virtio/Virtio.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

clean-whisper-api-smoke:
	rm -rf $(BUILD_DIR)

-include $(ALL_OBJECTS:.o=.d)
