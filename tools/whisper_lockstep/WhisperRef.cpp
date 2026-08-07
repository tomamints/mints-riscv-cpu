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


/*
 * Match the RTL PMP implementation.
 *
 * The RTL implements exactly eight PMP entries:
 *
 *   pmpaddr0 ... pmpaddr7
 *   pmpcfg0
 *
 * Whisper defines up to 64 PMP entries by default.  Mark every PMP CSR
 * above entry 7 as unimplemented so that accesses such as pmpaddr8 raise
 * an illegal-instruction exception, matching the RTL.
 */
template <typename HartType>
void configure_rtl_pmp_csrs(HartType& hart)
{
    constexpr bool implemented = false;
    constexpr std::uint64_t reset_value = 0;
    constexpr std::uint64_t write_mask = 0;
    constexpr std::uint64_t poke_mask = 0;
    constexpr bool shared = false;

    for (unsigned index = 8; index < 64; ++index) {
        const std::string name =
            "pmpaddr" + std::to_string(index);

        if (!hart.configCsr(
                name,
                implemented,
                reset_value,
                write_mask,
                poke_mask,
                shared)) {
            fail("failed to disable CSR: " + name);
        }
    }

    for (unsigned index = 2; index <= 14; index += 2) {
        const std::string name =
            "pmpcfg" + std::to_string(index);

        if (!hart.configCsr(
                name,
                implemented,
                reset_value,
                write_mask,
                poke_mask,
                shared)) {
            fail("failed to disable CSR: " + name);
        }
    }
}


constexpr std::uint32_t kOpcodeSystem = 0x73;
constexpr std::uint32_t kCsrTime = 0xc01;

bool is_csr_instruction_for(
    std::uint32_t inst,
    std::uint32_t expected_csr)
{
    const std::uint32_t opcode = inst & 0x7f;
    const std::uint32_t funct3 = (inst >> 12) & 0x7;
    const std::uint32_t csr = (inst >> 20) & 0xfff;

    return opcode == kOpcodeSystem &&
           funct3 != 0 &&
           csr == expected_csr;
}

bool is_time_csr_instruction(std::uint32_t inst)
{
    return is_csr_instruction_for(inst, kCsrTime);
}



template <typename HartType>
void configure_rtl_misa(HartType& hart)
{
    /*
     * Configure MISA as a static property of the RTL CPU before reset.
     *
     * configIsa() establishes Whisper's internal ISA-extension behavior.
     * We then replace the MISA reset value with the value architecturally
     * exposed by the RTL.  The CSR is read-only to guest instructions.
     */
    constexpr bool implemented = true;
    constexpr std::uint64_t write_mask = 0;
    constexpr std::uint64_t poke_mask = 0;
    constexpr bool shared = true;

    if (!hart.configCsr(
            "misa",
            implemented,
            kRtlMisa,
            write_mask,
            poke_mask,
            shared)) {
        fail("failed to configure RTL MISA value");
    }
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
     *   Supervisor mode (S)
     *   User mode (U)
     *   Zicsr
     *   Zifencei
     *   Zicntr
     *   Zicntr (cycle/time/instret CSRs)
     *
     * System<uint64_t> selects RV64, so the ISA string does not include
     * the "rv64" prefix.
     */
    constexpr bool update_misa = true;

    /*
     * S and U must be present in Whisper's internal ISA configuration, not
     * merely in the externally visible MISA CSR.  Hart::processExtensions()
     * enables supervisor/user mode only when both MISA.{S,U} and the
     * corresponding internal ISA-extension flags are set.
     */
    constexpr std::string_view isa =
        "imacsu_zicsr_zifencei_zicntr";

    if (!hart_->configIsa(isa, update_misa)) {
        fail(
            "failed to configure ISA: "
            "imacsu_zicsr_zifencei_zicntr");
    }

    /*
     * Static architectural CPU identity/configuration must be complete before
     * reset.  This avoids correcting MISA reads instruction-by-instruction.
     */
    configure_rtl_misa(*hart_);

    /*
     * Match the RTL's eight-entry PMP implementation before reset.
     * reset() rebuilds Whisper's cached PMP state from the implemented
     * CSR set, so the CSR configuration must already be complete here.
     */
    configure_rtl_pmp_csrs(*hart_);

    /*
     * Zicntr makes CYCLE, TIME, and INSTRET architecturally accessible.
     * The RTL exposes all three, including TIME backed by ACLINT mtime.
     */
    /*
     * The RTL implements MCYCLE/MINSTRET, but it does not implement the
     * optional MHPMCOUNTER3..31 or HPMCOUNTER3..31 register banks.
     *
     * OpenSBI probes MHPMCOUNTER3 with an expected-trap handler.  Whisper
     * enables performance counters by default, so configure both machine and
     * user counter banks to zero entries before reset.
     */
    if (!hart_->configMachineModePerfCounters(0, false))
        fail("failed to disable machine performance counters");

    if (!hart_->configUserModePerfCounters(0))
        fail("failed to disable user performance counters");

    /*
     * Whisper initializes the architectural state after ISA
     * configuration.
     *
     * Do not call reset() again after setting PC or boot registers.
     */
    hart_->reset();

    /*
     * Verify that reset preserved the RTL-specific MISA reset value.
     * If this fails, do not silently normalize later CSR reads: the reference
     * model configuration itself is wrong.
     */
    std::uint64_t whisper_misa = 0;

    if (!hart_->peekCsr(
            WdRiscv::CsrNumber::MISA,
            whisper_misa)) {
        fail("failed to read MISA after reset");
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

    if (whisper_misa != kRtlMisa) {
        std::ostringstream message;
        message
            << "MISA configuration mismatch after reset:"
            << " whisper=0x"
            << std::hex
            << whisper_misa
            << " rtl=0x"
            << kRtlMisa;
        fail(message.str());
    }

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

RefCommit WhisperRef::step(
    std::uint32_t rtl_inst,
    bool rtl_rd_we,
    unsigned rtl_rd,
    std::uint64_t rtl_rd_data)
{
    RefCommit result;

    /*
     * RTLのretire traceは、例外を起こした命令そのものをretireしない。
     *
     * WhisperのsingleStep()は、例外を起こした命令についても1回戻り、
     * PCをtrap vectorへ更新する。その結果を通常のcommitとして返すと、
     * RTLの次のretire命令（trap handler先頭）と1命令ずれる。
     *
     * そこで、命令を実行せずtrap/interrupt遷移だけが発生したstepは
     * 比較対象から除外し、次に実際に完了した命令を返す。
     */
    constexpr unsigned kMaxNonRetiringSteps = 16;

    for (unsigned attempt = 0; ; ++attempt) {
        if (attempt >= kMaxNonRetiringSteps) {
            fail(
                "too many consecutive non-retiring "
                "trap/interrupt steps");
        }

        result = RefCommit{};

        result.pc =
            hart_->peekPc();

        result.privilege =
            static_cast<unsigned>(
                hart_->privilegeMode());

        /*
         * Save trap-vector CSRs before executing the instruction.
         *
         * Whisper's lastInstructionTrapped()/Interrupted() metadata can remain
         * asserted while the handler itself is being executed.  EPC-based
         * filtering is also unsafe because handler code is allowed to read and
         * rewrite MEPC/SEPC.
         *
         * A real non-retiring trap transition is identified by the post-step
         * PC being the architectural trap-vector target.
         */
        std::uint64_t mtvec = 0;
        std::uint64_t stvec = 0;

        const bool have_mtvec =
            hart_->peekCsr(WdRiscv::CsrNumber::MTVEC, mtvec);

        const bool have_stvec =
            hart_->peekCsr(WdRiscv::CsrNumber::STVEC, stvec);

        hart_->singleStep(nullptr);

        result.next_pc =
            hart_->peekPc();

        result.trapped =
            hart_->lastInstructionTrapped();

        result.interrupted =
            hart_->lastInstructionInterrupted();

        if (result.trapped || result.interrupted) {
            result.trap_cause =
                static_cast<std::uint64_t>(
                    hart_->lastTrapCause());
        }

        const auto trap_target =
            [&](std::uint64_t tvec) -> std::uint64_t {
                const std::uint64_t base = tvec & ~std::uint64_t{3};
                const std::uint64_t mode = tvec & std::uint64_t{3};

                if (result.interrupted && mode == 1)
                    return base + 4 * result.trap_cause;

                return base;
            };

        const bool entered_mtvec =
            have_mtvec &&
            result.next_pc == trap_target(mtvec);

        const bool entered_stvec =
            have_stvec &&
            result.next_pc == trap_target(stvec);

        const bool non_retiring_event =
            (result.trapped || result.interrupted) &&
            (entered_mtvec || entered_stvec);

        if (!non_retiring_event)
            break;
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

    }

    /*
     * TIME is an external counter input from the RTL ACLINT clock domain.
     *
     * Whisper advances its shared time once per singleStep(), while the RTL
     * ACLINT mtime advances with RTL clock cycles.  Those clocks are not
     * expected to have the same value.  For a retiring TIME CSR read, use the
     * RTL architectural result and write it back into Whisper's destination
     * register so subsequent instructions observe the same state.
     */
    if (is_time_csr_instruction(rtl_inst)) {
        if (!rtl_rd_we || rtl_rd == 0 || rtl_rd >= 32) {
            fail("invalid RTL destination for TIME CSR synchronization");
        }

        if (!result.rd_we || result.rd != rtl_rd) {
            fail("RTL/Whisper destination mismatch during TIME synchronization");
        }

        if (!hart_->pokeIntReg(rtl_rd, rtl_rd_data)) {
            fail("failed to synchronize TIME result into Whisper integer register");
        }

        result.rd_data = rtl_rd_data;
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
