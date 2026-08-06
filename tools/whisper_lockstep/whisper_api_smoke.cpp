#include "WhisperRef.hpp"
#include <iomanip>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv)
{
    if (argc < 4 || argc > 6) {
        std::cerr << "usage: " << argv[0]
                  << " FW_JUMP_ELF DTB COUNT [LINUX_IMAGE] [LINUX_ADDRESS]\n";
        return 2;
    }

    try {
        mints::lockstep::WhisperConfig config;
        config.opensbi_elf = argv[1];
        config.dtb_binary = argv[2];
        const std::uint64_t count = std::stoull(argv[3], nullptr, 0);

        if (argc >= 5)
            config.linux_binary = argv[4];
        if (argc >= 6)
            config.linux_address = std::stoull(argv[5], nullptr, 0);

        mints::lockstep::WhisperRef ref(config);

        for (std::uint64_t order = 1; order <= count; ++order) {
            const auto c = ref.step();
            std::cout << "[WREF]"
                      << " order=" << std::dec << order
                      << " pc=" << std::hex << std::setw(16) << std::setfill('0') << c.pc
                      << " next_pc=" << std::setw(16) << c.next_pc
                      << " priv=" << std::dec << c.privilege
                      << " rd_we=" << c.rd_we
                      << " rd=" << c.rd
                      << " rd_data=" << std::hex << std::setw(16) << c.rd_data
                      << " mem_valid=" << std::dec << c.mem_valid
                      << " mem_write=" << c.mem_write
                      << " mem_pa=" << std::hex << std::setw(16) << c.mem_pa1
                      << " mem_size=" << std::dec << c.mem_size
                      << " mem_data=" << std::hex << std::setw(16) << c.mem_data
                      << " trap=" << std::dec << c.trapped
                      << " interrupt=" << c.interrupted
                      << " cause=" << std::hex << c.trap_cause
                      << '\n';

            if (c.trapped)
                return 1;
        }
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << '\n';
        return 2;
    }
}
