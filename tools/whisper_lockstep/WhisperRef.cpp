#include "WhisperRef.hpp"

#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace mints::lockstep {
namespace {

[[noreturn]] void fail(const std::string& message)
{
    throw std::runtime_error("WhisperRef: " + message);
}

std::string binary_spec(const std::string& path, std::uint64_t address)
{
    std::ostringstream out;
    out << path << ":0x" << std::hex << address;
    return out.str();
}

}  // namespace

WhisperRef::WhisperRef(const WhisperConfig& config)
    : system_(
          1,
          1,
          1,
          static_cast<std::size_t>(config.memory_size),
          static_cast<std::size_t>(config.page_size))
{
    hart_ = system_.ithHart(0);
    if (!hart_)
        fail("system has no hart 0");

    /*
     * Match the RTL CPU configuration:
     *
     *   RV64IMAC
     *   Zicsr
     *   Zifencei
     *
     * System<uint64_t> determines RV64, so Whisper's ISA string does not
     * include the "rv64" prefix.
     *
     * update_misa=true also updates the architectural misa CSR to match
     * the configured ISA.
     */
    constexpr bool update_misa = true;
    constexpr std::string_view isa = "imac_zicsr_zifencei";

    if (!hart_->configIsa(isa, update_misa))
        fail("failed to configure ISA: imac_zicsr_zifencei");
    /*
     * Whisper CLI also resets the Hart after configIsa().
     * This initializes architectural state using the selected ISA.
     */
    hart_->reset();

    if (!system_.loadElfFiles({config.opensbi_elf}, true, false))
        fail("failed to load OpenSBI ELF");

    std::vector<std::string> binaries;

    if (!config.dtb_binary.empty()) {
        binaries.push_back(
            binary_spec(config.dtb_binary, config.dtb_address));
    }

    if (!config.linux_binary.empty()) {
        binaries.push_back(
            binary_spec(config.linux_binary, config.linux_address));
    }

    if (!binaries.empty() &&
        !system_.loadBinaryFiles(binaries, 0, false)) {
        fail("failed to load binary image");
    }

    hart_->pokePc(config.start_pc);

    if (!hart_->pokeIntReg(10, config.hart_id))
        fail("failed to initialize x10");

    if (!hart_->pokeIntReg(11, config.dtb_address))
        fail("failed to initialize x11");
}

std::uint64_t WhisperRef::pc() const
{
    return hart_->peekPc();
}

std::uint64_t WhisperRef::int_reg(unsigned reg) const
{
    if (reg >= 32)
        fail("integer register index is out of range");

    return hart_->peekIntReg(reg);
}

RefCommit WhisperRef::step()
{
    RefCommit result;

    result.pc = hart_->peekPc();
    result.privilege =
        static_cast<unsigned>(hart_->privilegeMode());

    hart_->singleStep(nullptr);

    result.next_pc = hart_->peekPc();
    result.trapped = hart_->lastInstructionTrapped();
    result.interrupted = hart_->lastInstructionInterrupted();

    if (result.trapped) {
        result.trap_cause =
            static_cast<std::uint64_t>(hart_->lastTrapCause());
    }

    std::uint64_t rd_value = 0;
    const int rd = hart_->lastIntReg(rd_value);

    if (rd > 0) {
        result.rd_we = true;
        result.rd = static_cast<unsigned>(rd);
        result.rd_data = rd_value;
    }

    std::uint64_t va = 0;
    std::uint64_t pa1 = 0;
    std::uint64_t pa2 = 0;

    const unsigned ldst_size =
        hart_->lastLdStAddress(va, pa1, pa2);

    if (ldst_size != 0) {
        result.mem_valid = true;
        result.mem_va = va;
        result.mem_pa1 = pa1;
        result.mem_pa2 = pa2;
        result.mem_size = ldst_size;
    }

    std::uint64_t store_va = 0;
    std::uint64_t store_pa1 = 0;
    std::uint64_t store_pa2 = 0;
    std::uint64_t store_value = 0;

    const unsigned store_size =
        hart_->lastStore(
            store_va,
            store_pa1,
            store_pa2,
            store_value);

    if (store_size != 0) {
        result.mem_valid = true;
        result.mem_write = true;
        result.mem_va = store_va;
        result.mem_pa1 = store_pa1;
        result.mem_pa2 = store_pa2;
        result.mem_size = store_size;
        result.mem_data = store_value;
    } else if (result.mem_valid && result.rd_we) {
        /*
         * For loads, Whisper exposes the architectural destination-register
         * result rather than a separate raw memory-data field.
         */
        result.mem_data = result.rd_data;
    }

    std::vector<WdRiscv::CsrNumber> csrs;
    hart_->lastCsr(csrs);

    for (const auto csr : csrs) {
        result.csr_writes.push_back({
            static_cast<unsigned>(csr),
            static_cast<std::uint64_t>(
                hart_->lastCsrValue(csr))
        });
    }

    return result;
}

}  // namespace mints::lockstep
