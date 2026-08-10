#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "System.hpp"
#include "Hart.hpp"

namespace mints::lockstep {

struct CsrWrite {
    unsigned number = 0;
    std::uint64_t value = 0;
};

struct RefCommit {
    std::uint64_t pc = 0;
    std::uint64_t next_pc = 0;
    unsigned privilege = 0;

    bool rd_we = false;
    unsigned rd = 0;
    std::uint64_t rd_data = 0;

    bool mem_valid = false;
    bool mem_write = false;
    std::uint64_t mem_va = 0;
    std::uint64_t mem_pa1 = 0;
    std::uint64_t mem_pa2 = 0;
    unsigned mem_size = 0;
    std::uint64_t mem_data = 0;

    bool trapped = false;
    bool interrupted = false;
    std::uint64_t trap_cause = 0;

    std::vector<CsrWrite> csr_writes;
};

struct WhisperConfig {
    std::string opensbi_elf;
    std::string dtb_binary;
    std::string linux_binary;

    std::uint64_t start_pc = 0x80000000;
    std::uint64_t hart_id = 0;
    std::uint64_t dtb_address = 0x87f00000;
    std::uint64_t linux_address = 0x80200000;
    std::uint64_t memory_size = 0x88000000;
    std::uint64_t page_size = 4096;
};

class WhisperRef {
public:
    explicit WhisperRef(const WhisperConfig& config);

    /*
     * rtl_* describes the RTL instruction retiring in lockstep with this
     * Whisper step. External counter CSRs such as TIME and MMIO reads are
     * synchronized from the RTL because they are driven by RTL/external state
     * rather than by Whisper's instruction-step memory model.
     *
     * rtl_mem_addr is the architectural virtual address. rtl_mem_pa is the
     * physical address actually used by the RTL data-memory path.
     */
    RefCommit step(
        std::uint32_t rtl_inst,
        bool rtl_rd_we,
        unsigned rtl_rd,
        std::uint64_t rtl_rd_data,
        bool rtl_mem_valid,
        bool rtl_mem_write,
        std::uint64_t rtl_mem_addr,
        std::uint64_t rtl_mem_pa,
        std::uint8_t rtl_mem_mask,
        std::uint64_t rtl_mem_data,
        bool rtl_mtip,
        bool rtl_seip,
        bool rtl_interrupt_from_wfi,
        std::uint64_t rtl_interrupt_epc);

    RefCommit step_non_retiring_trap(
        bool rtl_mtip,
        bool rtl_seip);

    std::uint64_t pc() const;
    std::uint64_t int_reg(unsigned reg) const;

private:
    using System64 = WdRiscv::System<std::uint64_t>;
    using Hart64 = WdRiscv::Hart<std::uint64_t>;

    System64 system_;
    std::shared_ptr<Hart64> hart_;

    void synchronize_interrupts(bool rtl_mtip, bool rtl_seip);
};

}  // namespace mints::lockstep
