// DPI-C stubs for standalone unit tests that compile src/util.sv
// (tb/tb_verilator.cpp provides these for the CPU simulator).
#include <cstdlib>
extern "C" const char* get_env_value(const char* key)
{
    const char* value = std::getenv(key);
    return value ? value : "";
}
extern "C" const unsigned long long get_input_dpic()
{
    return 0;
}
