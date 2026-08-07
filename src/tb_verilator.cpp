#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <memory>
#include <signal.h>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

/*
 * Whisper must be included before termios.h.
 *
 * Linux termios.h defines VSTART as a preprocessor macro.
 * Whisper uses VSTART as CsrNumber::VSTART, so including termios.h first
 * corrupts the Whisper header during preprocessing.
 */
#ifdef SVCPU_WHISPER_LOCKSTEP
#include "WhisperRef.hpp"
#endif

#include <termios.h>

#ifdef VSTART
#undef VSTART
#endif

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vcore_top.h"

namespace fs = std::filesystem;

extern "C" const char* get_env_value(const char* key)
{
    const char* value = std::getenv(key);
    return value == nullptr ? "" : value;
}

extern "C" const unsigned long long get_input_dpic()
{
    unsigned char c = 0;
    const ssize_t bytes_read = read(STDIN_FILENO, &c, 1);

    if (bytes_read == 1)
        return static_cast<unsigned long long>(c) | (0x01010ULL << 44);

    return 0;
}

namespace {

struct termios old_setting {};
bool termios_changed = false;

void restore_termios_setting()
{
    if (termios_changed)
        tcsetattr(STDIN_FILENO, TCSANOW, &old_setting);
}

void sighandler(int signum)
{
    restore_termios_setting();
    std::_Exit(signum);
}

void set_nonblocking()
{
    if (!isatty(STDIN_FILENO))
        return;

    if (tcgetattr(STDIN_FILENO, &old_setting) == -1) {
        perror("tcgetattr");
        return;
    }

    struct termios new_setting = old_setting;

    // Ctrl-C remains enabled. Linux ttyS0 performs echo.
    new_setting.c_lflag &= static_cast<tcflag_t>(~(ICANON | ECHO));
    new_setting.c_cc[VMIN] = 0;
    new_setting.c_cc[VTIME] = 0;

    if (tcsetattr(STDIN_FILENO, TCSANOW, &new_setting) == -1) {
        perror("tcsetattr");
        return;
    }

    termios_changed = true;
    signal(SIGINT, sighandler);
    signal(SIGTERM, sighandler);
    signal(SIGQUIT, sighandler);
    atexit(restore_termios_setting);

    const int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    if (flags == -1) {
        perror("fcntl(F_GETFL)");
        return;
    }

    if (fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == -1)
        perror("fcntl(F_SETFL)");
}

#ifdef SVCPU_WHISPER_LOCKSTEP

std::uint64_t value_mask_for_size(unsigned size)
{
    if (size == 0)
        return 0;
    if (size >= 8)
        return ~std::uint64_t{0};
    return (std::uint64_t{1} << (size * 8)) - 1;
}

unsigned first_set_lane(std::uint8_t mask)
{
    for (unsigned lane = 0; lane < 8; ++lane) {
        if ((mask & (std::uint8_t{1} << lane)) != 0)
            return lane;
    }
    return 0;
}

unsigned size_from_byte_mask(std::uint8_t mask)
{
    unsigned count = 0;
    for (unsigned lane = 0; lane < 8; ++lane)
        count += (mask >> lane) & 1u;

    switch (count) {
    case 1:
    case 2:
    case 4:
    case 8:
        return count;
    default:
        return 0;
    }
}

std::uint64_t normalize_rtl_store_data(
    std::uint64_t lane_aligned_data,
    std::uint8_t byte_mask)
{
    const unsigned size = size_from_byte_mask(byte_mask);
    const unsigned lane = first_set_lane(byte_mask);

    if (size == 0)
        return lane_aligned_data;

    return (lane_aligned_data >> (lane * 8)) & value_mask_for_size(size);
}

bool compare_commit(
    std::uint64_t order,
    const Vcore_top& dut,
    const mints::lockstep::RefCommit& ref)
{
    bool ok = true;
    std::ostringstream differences;

    const auto add_difference = [&](const std::string& text) {
        ok = false;
        differences << "\n  - " << text;
    };

    const std::uint64_t rtl_pc = static_cast<std::uint64_t>(dut.retire_pc);
    const std::uint32_t rtl_inst = static_cast<std::uint32_t>(dut.retire_inst);
    const unsigned rtl_priv = static_cast<unsigned>(dut.retire_priv);

    if (rtl_pc != ref.pc) {
        std::ostringstream text;
        text << "pc: rtl=0x" << std::hex << rtl_pc
             << " ref=0x" << ref.pc;
        add_difference(text.str());
    }

    if (rtl_priv != ref.privilege) {
        std::ostringstream text;
        text << "privilege: rtl=" << rtl_priv
             << " ref=" << ref.privilege;
        add_difference(text.str());
    }

    const bool rtl_rd_we = dut.retire_rd_we != 0;
    if (rtl_rd_we != ref.rd_we) {
        std::ostringstream text;
        text << "rd_we: rtl=" << rtl_rd_we
             << " ref=" << ref.rd_we;
        add_difference(text.str());
    } else if (rtl_rd_we) {
        const unsigned rtl_rd = static_cast<unsigned>(dut.retire_rd_addr);
        const std::uint64_t rtl_rd_data =
            static_cast<std::uint64_t>(dut.retire_rd_data);

        if (rtl_rd != ref.rd) {
            std::ostringstream text;
            text << "rd: rtl=x" << rtl_rd << " ref=x" << ref.rd;
            add_difference(text.str());
        }

        if (rtl_rd_data != ref.rd_data) {
            std::ostringstream text;
            text << "rd_data: rtl=0x" << std::hex << rtl_rd_data
                 << " ref=0x" << ref.rd_data;
            add_difference(text.str());
        }
    }

    const bool rtl_mem_valid = dut.retire_mem_valid != 0;
    if (rtl_mem_valid != ref.mem_valid) {
        std::ostringstream text;
        text << "mem_valid: rtl=" << rtl_mem_valid
             << " ref=" << ref.mem_valid;
        add_difference(text.str());
    } else if (rtl_mem_valid) {
        const bool rtl_mem_write = dut.retire_mem_write != 0;
        const std::uint64_t rtl_mem_addr =
            static_cast<std::uint64_t>(dut.retire_mem_addr);
        const std::uint8_t rtl_mem_mask =
            static_cast<std::uint8_t>(dut.retire_mem_mask);
        const unsigned rtl_mem_size = size_from_byte_mask(rtl_mem_mask);

        if (rtl_mem_write != ref.mem_write) {
            std::ostringstream text;
            text << "mem_write: rtl=" << rtl_mem_write
                 << " ref=" << ref.mem_write;
            add_difference(text.str());
        }

        if (rtl_mem_addr != ref.mem_va) {
            std::ostringstream text;
            text << "mem_addr: rtl=0x" << std::hex << rtl_mem_addr
                << " ref_va=0x" << ref.mem_va
                << " ref_pa=0x" << ref.mem_pa1;
            add_difference(text.str());
        }

        // Current RTL emits a byte mask only for writes. For loads, size is
        // already checked indirectly through destination-register effects.
        if (rtl_mem_write && rtl_mem_size != ref.mem_size) {
            std::ostringstream text;
            text << "mem_size: rtl=" << std::dec << rtl_mem_size
                 << " ref=" << ref.mem_size
                 << " rtl_mask=0x" << std::hex
                 << static_cast<unsigned>(rtl_mem_mask);
            add_difference(text.str());
        }

        if (rtl_mem_write && ref.mem_write) {
            const std::uint64_t rtl_store_data = normalize_rtl_store_data(
                static_cast<std::uint64_t>(dut.retire_mem_data),
                rtl_mem_mask);
            const std::uint64_t mask = value_mask_for_size(ref.mem_size);

            if ((rtl_store_data & mask) != (ref.mem_data & mask)) {
                std::ostringstream text;
                text << "mem_data: rtl=0x" << std::hex
                     << (rtl_store_data & mask)
                     << " ref=0x" << (ref.mem_data & mask)
                     << " raw_rtl=0x"
                     << static_cast<std::uint64_t>(dut.retire_mem_data)
                     << " rtl_mask=0x"
                     << static_cast<unsigned>(rtl_mem_mask);
                add_difference(text.str());
            }
        }
    }

    if (!ok) {
        if (rtl_mem_valid) {
            differences
                << "\n  - mem_context:"
                << " rtl_addr=0x" << std::hex
                << static_cast<std::uint64_t>(dut.retire_mem_addr)
                << " ref_pa=0x" << ref.mem_pa1
                << " ref_va=0x" << ref.mem_va
                << " ref_size=" << std::dec << ref.mem_size
                << " rtl_write=" << (dut.retire_mem_write != 0);
        }

        std::cerr
            << "\n[LOCKSTEP-MISMATCH]"
            << " order=" << std::dec << order
            << " rtl_pc=0x" << std::hex << rtl_pc
            << " rtl_inst=0x" << std::setw(8) << std::setfill('0')
            << rtl_inst
            << " ref_next_pc=0x" << ref.next_pc
            << differences.str()
            << '\n';
    }

    return ok;
}

std::string required_environment(const char* name)
{
    const char* value = std::getenv(name);
    if (value == nullptr || value[0] == '\0') {
        throw std::runtime_error(
            std::string("missing required environment variable: ") + name);
    }
    return value;
}

std::unique_ptr<mints::lockstep::WhisperRef> create_whisper_reference()
{
    mints::lockstep::WhisperConfig config;

    config.opensbi_elf = required_environment("WHISPER_OPENSBI_ELF");

    if (const char* dtb = std::getenv("WHISPER_DTB"); dtb != nullptr)
        config.dtb_binary = dtb;

    if (const char* linux = std::getenv("WHISPER_LINUX"); linux != nullptr)
        config.linux_binary = linux;

    config.start_pc = 0x80000000;
    config.hart_id = 0;
    config.dtb_address = 0x87f00000;
    config.linux_address = 0x80200000;

    auto whisper =
        std::make_unique<mints::lockstep::WhisperRef>(config);

    std::cerr
        << "[LOCKSTEP] Whisper enabled"
        << " start_pc=0x" << std::hex << config.start_pc
        << " opensbi=" << config.opensbi_elf;

    if (!config.dtb_binary.empty())
        std::cerr << " dtb=" << config.dtb_binary;
    if (!config.linux_binary.empty())
        std::cerr << " linux=" << config.linux_binary;

    std::cerr << '\n';
    return whisper;
}

#endif  // SVCPU_WHISPER_LOCKSTEP

}  // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);

    std::vector<std::string> positional_args;
    for (int i = 1; i < argc; ++i) {
        if (argv[i][0] != '+')
            positional_args.emplace_back(argv[i]);
    }

    if (positional_args.size() < 2) {
        std::cout
            << "Usage: " << argv[0]
            << " ROM_FILE_PATH RAM_FILE_PATH [CYCLE]\n";
        return 1;
    }

#ifdef ENABLE_DEBUG_INPUT
    set_nonblocking();
#endif

    std::string rom_file_path = positional_args[0];
    std::string ram_file_path = positional_args[1];

    try {
        rom_file_path = fs::absolute(rom_file_path).string();
        ram_file_path = fs::absolute(ram_file_path).string();
    } catch (const std::exception& error) {
        std::cerr << "Invalid memory file path: " << error.what() << '\n';
        return 1;
    }

    unsigned long long cycles = 0;
    if (positional_args.size() >= 3) {
        try {
            cycles = std::stoull(positional_args[2]);
        } catch (const std::exception&) {
            std::cerr << "Invalid number: " << positional_args[2] << '\n';
            return 1;
        }
    }

    const char* old_rom_env = std::getenv("ROM_FILE_PATH");
    const char* old_ram_env = std::getenv("RAM_FILE_PATH");
    const std::string old_rom = old_rom_env == nullptr ? "" : old_rom_env;
    const std::string old_ram = old_ram_env == nullptr ? "" : old_ram_env;
    const bool had_old_rom = old_rom_env != nullptr;
    const bool had_old_ram = old_ram_env != nullptr;

    setenv("ROM_FILE_PATH", rom_file_path.c_str(), 1);
    setenv("RAM_FILE_PATH", ram_file_path.c_str(), 1);

    const char* dbg_addr_text = std::getenv("DBG_ADDR");
    const unsigned long long dbg_addr =
        dbg_addr_text == nullptr
            ? 0
            : std::strtoull(dbg_addr_text, nullptr, 0);

    auto dut = std::make_unique<Vcore_top>();
    dut->MMAP_DBG_ADDR = dbg_addr;

    // Active-low reset.
    dut->clk = 0;
    dut->rst = 1;
    dut->eval();

    constexpr int reset_half_cycles = 4;
    for (int i = 0; i < reset_half_cycles; ++i) {
        dut->clk = !dut->clk;
        dut->rst = 0;
        dut->eval();
    }

    dut->clk = 0;
    dut->rst = 1;
    dut->eval();

    if (had_old_rom)
        setenv("ROM_FILE_PATH", old_rom.c_str(), 1);
    else
        unsetenv("ROM_FILE_PATH");

    if (had_old_ram)
        setenv("RAM_FILE_PATH", old_ram.c_str(), 1);
    else
        unsetenv("RAM_FILE_PATH");

#ifdef TRACE
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    dut->trace(tfp.get(), 100);
    tfp->open("sim.vcd");
#endif

#ifdef SVCPU_WHISPER_LOCKSTEP
    std::unique_ptr<mints::lockstep::WhisperRef> whisper;
    try {
        whisper = create_whisper_reference();
    } catch (const std::exception& error) {
        std::cerr << "[LOCKSTEP] initialization failed: "
                  << error.what() << '\n';
        return 1;
    }

    constexpr std::uint64_t lockstep_start_pc = 0x80000000;
    std::uint64_t rtl_retire_order = 0;
    std::uint64_t compared_order = 0;
    bool lockstep_started = false;
    bool lockstep_failed = false;
#endif

    for (long long half_cycle = 0;
         !Verilated::gotFinish()
#ifdef SVCPU_WHISPER_LOCKSTEP
             && !lockstep_failed
#endif
             && (cycles == 0 || half_cycle / 2 < static_cast<long long>(cycles));
         ++half_cycle) {
        dut->clk = !dut->clk;
        dut->eval();

#ifdef SVCPU_WHISPER_LOCKSTEP
        // Observe retire once, immediately after the rising-edge evaluation.
        if (dut->clk == 1 && dut->retire_valid) {
            ++rtl_retire_order;

            const std::uint64_t rtl_pc =
                static_cast<std::uint64_t>(dut->retire_pc);

            // RTL executes the small boot ROM first. Whisper starts directly
            // at OpenSBI, therefore comparison begins at 0x80000000.
            if (!lockstep_started && rtl_pc == lockstep_start_pc) {
                lockstep_started = true;
                std::cerr
                    << "[LOCKSTEP] comparison started"
                    << " rtl_retire_order=" << std::dec << rtl_retire_order
                    << " pc=0x" << std::hex << rtl_pc << '\n';
            }

            if (lockstep_started) {
                ++compared_order;
                const auto ref = whisper->step(
                    static_cast<std::uint32_t>(dut->retire_inst),
                    static_cast<bool>(dut->retire_rd_we),
                    static_cast<unsigned>(dut->retire_rd_addr),
                    static_cast<std::uint64_t>(dut->retire_rd_data),
                    static_cast<bool>(dut->retire_mem_valid),
                    static_cast<bool>(dut->retire_mem_write),
                    static_cast<std::uint64_t>(dut->retire_mem_addr),
                    static_cast<std::uint8_t>(dut->retire_mem_mask),
                    static_cast<std::uint64_t>(dut->retire_mem_data));

                if (!compare_commit(compared_order, *dut, ref)) {
                    lockstep_failed = true;
                } else if ((compared_order % 10000) == 0) {
                    std::cerr
                        << "[LOCKSTEP] passed " << std::dec
                        << compared_order << " instructions"
                        << " pc=0x" << std::hex << rtl_pc << '\n';
                }
            }
        }
#endif

#ifdef TRACE
        tfp->dump(static_cast<vluint64_t>(half_cycle));
        tfp->flush();
#endif
    }

    dut->final();

    std::cout << std::flush;
    std::cerr << std::flush;
    fflush(stdout);
    fflush(stderr);

#ifdef TRACE
    tfp->close();
#endif

#ifdef SVCPU_WHISPER_LOCKSTEP
    if (lockstep_failed)
        return 2;

    if (!lockstep_started) {
        std::cerr
            << "[LOCKSTEP] comparison never started: RTL did not retire pc=0x"
            << std::hex << lockstep_start_pc << '\n';
        return 3;
    }

    std::cerr
        << "[LOCKSTEP] PASS: " << std::dec << compared_order
        << " instructions compared\n";
#endif

#ifdef TEST_MODE
    return dut->test_success != 1;
#else
    return 0;
#endif
}
