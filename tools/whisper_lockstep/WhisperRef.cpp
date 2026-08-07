#include "WhisperRef.hpp"

#include <cstdint>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace mints::lockstep {
namespace {

/*
 * RTLが公開するmisa値。
 *
 * MXL = RV64
 * Extensions = A, C, I, M, S, U
 *
 * F、D、VはRTLでは未実装。
 */
constexpr std::uint64_t kRtlMisa =
    0x8000000000141105ULL;

[[noreturn]] void fail(const std::string& message)
{
    throw std::runtime_error("WhisperRef: " + message);
}

std::string binary_spec(
    const std::string& path,
    std::uint64_t address)
{
    std::ostringstream out;

    out
        << path
        << ":0x"
        << std::hex
        << address;

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
     * System<uint64_t> selects RV64, so the ISA string does not include
     * the "rv64" prefix.
     */
    constexpr bool update_misa = true;

    constexpr std::string_view isa =
        "imac_zicsr_zifencei";

    if (!hart_->configIsa(isa, update_misa)) {
        fail(
            "failed to configure ISA: "
            "imac_zicsr_zifencei");
    }

    /*
     * Whisper initializes the architectural state after ISA
     * configuration.
     *
     * Do not call reset() again after setting PC or boot registers.
     */
    hart_->reset();

    /*
     * Whisperの現在のmisaを確認する。
     *
     * Whisperではmisaの一部ビットがCSRの書き込みマスクによって
     * 固定されているため、pokeCsr()でRTL値へ変更することはしない。
     *
     * misaを読み出す命令についてはstep()内でRTL値へ正規化する。
     */
    std::uint64_t whisper_misa = 0;

    if (!hart_->peekCsr(
            WdRiscv::CsrNumber::MISA,
            whisper_misa)) {
        fail("failed to read misa");
    }

    std::cerr
        << "[LOCKSTEP] misa"
        << " whisper=0x"
        << std::hex
        << whisper_misa
        << " rtl=0x"
        << kRtlMisa
        << std::dec
        << '\n';

    /*
     * Load OpenSBI ELF into Whisper memory.
     */
    if (!system_.loadElfFiles(
            {config.opensbi_elf},
            true,
            false)) {
        fail("failed to load OpenSBI ELF");
    }

    /*
     * Load raw DTB and Linux images at the same guest physical
     * addresses used by the RTL simulation.
     */
    std::vector<std::string> binaries;

    if (!config.dtb_binary.empty()) {
        binaries.push_back(
            binary_spec(
                config.dtb_binary,
                config.dtb_address));
    }

    if (!config.linux_binary.empty()) {
        binaries.push_back(
            binary_spec(
                config.linux_binary,
                config.linux_address));
    }

    if (!binaries.empty()) {
        if (!system_.loadBinaryFiles(
                binaries,
                0,
                false)) {
            fail("failed to load binary image");
        }
    }

    /*
     * RISC-V firmware entry state:
     *
     *   PC = OpenSBI entry point
     *   a0 = boot hart ID
     *   a1 = DTB guest physical address
     */
    hart_->pokePc(config.start_pc);

    if (!hart_->pokeIntReg(
            10,
            config.hart_id)) {
        fail("failed to initialize x10/a0");
    }

    if (!hart_->pokeIntReg(
            11,
            config.dtb_address)) {
        fail("failed to initialize x11/a1");
    }

    /*
     * Read back the initial architectural state immediately.
     */
    const std::uint64_t actual_pc =
        hart_->peekPc();

    const std::uint64_t actual_a0 =
        hart_->peekIntReg(10);

    const std::uint64_t actual_a1 =
        hart_->peekIntReg(11);

    std::cerr
        << "[LOCKSTEP] Whisper initial state"
        << " pc=0x"
        << std::hex
        << actual_pc
        << " a0=0x"
        << actual_a0
        << " a1=0x"
        << actual_a1
        << std::dec
        << '\n';

    if (actual_pc != config.start_pc) {
        std::ostringstream message;

        message
            << "PC read-back mismatch:"
            << " requested=0x"
            << std::hex
            << config.start_pc
            << " actual=0x"
            << actual_pc;

        fail(message.str());
    }

    if (actual_a0 != config.hart_id) {
        std::ostringstream message;

        message
            << "x10/a0 read-back mismatch:"
            << " requested=0x"
            << std::hex
            << config.hart_id
            << " actual=0x"
            << actual_a0;

        fail(message.str());
    }

    if (actual_a1 != config.dtb_address) {
        std::ostringstream message;

        message
            << "x11/a1 read-back mismatch:"
            << " requested=0x"
            << std::hex
            << config.dtb_address
            << " actual=0x"
            << actual_a1;

        fail(message.str());
    }
}

std::uint64_t WhisperRef::pc() const
{
    return hart_->peekPc();
}

std::uint64_t WhisperRef::int_reg(
    unsigned reg) const
{
    if (reg >= 32)
        fail("integer register index is out of range");

    return hart_->peekIntReg(reg);
}

RefCommit WhisperRef::step()
{
    RefCommit result;

    /*
     * Architectural state before executing the instruction.
     */
    result.pc =
        hart_->peekPc();

    result.privilege =
        static_cast<unsigned>(
            hart_->privilegeMode());

    /*
     * Execute one architectural instruction.
     */
    hart_->singleStep(nullptr);

    /*
     * Architectural state after executing the instruction.
     */
    result.next_pc =
        hart_->peekPc();

    result.trapped =
        hart_->lastInstructionTrapped();

    result.interrupted =
        hart_->lastInstructionInterrupted();

    if (result.trapped) {
        result.trap_cause =
            static_cast<std::uint64_t>(
                hart_->lastTrapCause());
    }

    /*
     * Get the integer destination-register number from Whisper's
     * last-instruction metadata.
     *
     * lastIntReg() is used only to identify rd.
     * The final architectural value is read directly from the Hart.
     */
    std::uint64_t recorded_rd_value = 0;

    const int rd =
        hart_->lastIntReg(recorded_rd_value);

    if (rd > 0) {
        if (rd >= 32) {
            fail(
                "Whisper returned invalid integer "
                "destination register");
        }

        result.rd_we = true;

        result.rd =
            static_cast<unsigned>(rd);

        result.rd_data =
            hart_->peekIntReg(
                static_cast<unsigned>(rd));

        /*
         * Whisperのmisaは、内部のCSR設定によりF、D、Vビットを
         * 含んだ値を返す。
         *
         * RTLはF、D、Vを実装していないため、misa読み出し結果を
         * RTLが公開する値へ正規化する。
         *
         * Whisperの現在のmisa値と完全一致するレジスタ書き込みだけを
         * 置換するため、通常の演算結果には影響しない。
         */
        std::uint64_t whisper_misa = 0;

        if (!hart_->peekCsr(
                WdRiscv::CsrNumber::MISA,
                whisper_misa)) {
            fail("failed to read misa while normalizing rd_data");
        }

        if (result.rd_data == whisper_misa) {
            result.rd_data =
                kRtlMisa;
        }
    }

    /*
     * Capture the most recent load/store address.
     */
    std::uint64_t va = 0;
    std::uint64_t pa1 = 0;
    std::uint64_t pa2 = 0;

    const unsigned ldst_size =
        hart_->lastLdStAddress(
            va,
            pa1,
            pa2);

    if (ldst_size != 0) {
        result.mem_valid = true;

        result.mem_va =
            va;

        result.mem_pa1 =
            pa1;

        result.mem_pa2 =
            pa2;

        result.mem_size =
            ldst_size;
    }

    /*
     * Capture store details separately because lastLdStAddress()
     * does not distinguish loads from stores.
     */
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

        result.mem_va =
            store_va;

        result.mem_pa1 =
            store_pa1;

        result.mem_pa2 =
            store_pa2;

        result.mem_size =
            store_size;

        result.mem_data =
            store_value;
    } else if (
        result.mem_valid &&
        result.rd_we) {
        /*
         * For a normal load, use the final architectural destination
         * register value as the loaded value.
         */
        result.mem_data =
            result.rd_data;
    }

    /*
     * Capture CSR writes made by the instruction.
     */
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
