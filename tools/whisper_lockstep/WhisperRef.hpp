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
    RefCommit step();
    std::uint64_t pc() const;
    std::uint64_t int_reg(unsigned reg) const;

private:
    using System64 = WdRiscv::System<std::uint64_t>;
    using Hart64 = WdRiscv::Hart<std::uint64_t>;
    System64 system_;
    std::shared_ptr<Hart64> hart_;
};

}  // namespace mints::lockstep
