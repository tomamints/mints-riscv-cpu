// Host side of fpga/de0-cv/rtl/jtag_block_mailbox.sv over openFPGALoader's
// USB-Blaster transport. Requires one Cyclone V A4 with one virtual JTAG node.
//
//   de0cv-jtag-load status
//   de0cv-jtag-load load    IMAGE.hex   clear all RAM, write, read back, compare
//   de0cv-jtag-load verify  IMAGE.hex   read back and compare only
//   de0cv-jtag-load release IMAGE.hex   read back and compare, then release CPU
//
// IMAGE.hex is the sparse format of tools/make_linux_ram_hex.py with eight
// bytes per line ("@<word index>" lines, then one 16-digit word per line).
// The CPU is released only after every image word has been read back and
// matched in the same invocation; any mismatch or error leaves it held.
#include "jtag.hpp"
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint64_t RUN_WORD = 0x4d494e545352554eULL; // "MINTSRUN"
constexpr unsigned IR_STATUS = 0, IR_CMD = 1, IR_DATA = 2;
constexpr unsigned OP_WRITE = 0, OP_READ = 1, OP_CLEAR = 2, OP_RELEASE = 3;

struct Status {
    uint64_t raw;
    bool req() const { return raw & 1; }
    bool ack() const { return raw >> 1 & 1; }
    bool error() const { return raw >> 2 & 1; }
    bool cleared() const { return raw >> 3 & 1; }
    bool run() const { return raw >> 4 & 1; }
    bool fault() const { return raw >> 5 & 1; }
    bool memory_fault() const { return raw >> 6 & 1; }
    unsigned op() const { return raw >> 8 & 3; }
    bool cmd_dropped() const { return raw >> 10 & 1; }
    bool data_dropped() const { return raw >> 11 & 1; }
    unsigned block_log2() const { return raw >> 24 & 255; }
    unsigned count() const { return raw >> 32 & 0xffff; }
};

class Mailbox {
public:
    Mailbox() : pins_{}, j_(cable_list.at("usb-blaster"), &pins_, "", "", 6000000, 0, "", 0) {
        auto ids = j_.get_devices_list();
        if (ids.size() != 1 || ids[0] != 0x02b050dd) throw std::runtime_error("expected single Cyclone V A4");
        j_.device_select(0);
        j_.go_test_logic_reset();
        instruction(0x00e); dr_word(0, 64);
        instruction(0x00c);
        uint32_t hub = info();
        unsigned nodes = (hub >> 19) & 255;
        m_ = hub & 255;
        if (((hub >> 8) & 2047) != 0x06e || nodes != 1 || m_ < 3 || m_ > 16)
            throw std::runtime_error("expected one SLD node with supported VIR width");
        uint32_t node = info();
        if (((node >> 19) & 255) != 8 || (node & 255) != 0)
            throw std::runtime_error("expected virtual JTAG node instance zero");
        Status s = status();
        if ((s.raw >> 48) != 0x4a4d) throw std::runtime_error("mailbox magic not found");
        block_ = 1u << s.block_log2();
    }
    ~Mailbox() { try { j_.go_test_logic_reset(); } catch (...) {} }
    unsigned block() const { return block_; }

    Status status() {
        select(IR_STATUS);
        return Status{dr_word(0, 64)};
    }
    // Issue a command and wait for its result.
    Status command(unsigned op, unsigned count, uint64_t word_offset, double timeout_s) {
        if (word_offset >> 32) throw std::runtime_error("offset out of range");
        uint64_t word = 0x4a42ULL << 48 | word_offset << 16 | uint64_t(count & 0x3fff) << 2 | op;
        Status before = status();
        if (before.req() != before.ack()) throw std::runtime_error("mailbox busy before command");
        if (before.data_dropped()) throw std::runtime_error("mailbox dropped block data");
        select(IR_CMD);
        dr_word(word, 64);
        auto start = std::chrono::steady_clock::now();
        for (;;) {
            Status s = status();
            if (s.cmd_dropped()) throw std::runtime_error("mailbox dropped command");
            if (s.req() == before.req()) throw std::runtime_error("command not accepted");
            if (s.req() == s.ack()) {
                if (s.op() != op) throw std::runtime_error("result is for another command");
                return s;
            }
            double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
            if (t > timeout_s) throw std::runtime_error("command timeout");
        }
    }
    void put(const std::vector<uint64_t> &words) {
        std::vector<uint8_t> tx(words.size() * 8), rx(words.size() * 8);
        for (size_t i = 0; i < words.size(); i++)
            for (int b = 0; b < 8; b++) tx[i * 8 + b] = uint8_t(words[i] >> (8 * b));
        select(IR_DATA);
        if (j_.shiftDR(tx.data(), rx.data(), int(words.size() * 64)) < 0) throw std::runtime_error("DR scan failed");
    }
    std::vector<uint64_t> get(size_t n) {
        std::vector<uint8_t> tx(n * 8, 0), rx(n * 8, 0);
        select(IR_DATA);
        if (j_.shiftDR(tx.data(), rx.data(), int(n * 64)) < 0) throw std::runtime_error("DR scan failed");
        std::vector<uint64_t> w(n, 0);
        for (size_t i = 0; i < n; i++)
            for (int b = 0; b < 8; b++) w[i] |= uint64_t(rx[i * 8 + b]) << (8 * b);
        return w;
    }

private:
    void instruction(uint16_t value) {
        uint8_t bytes[2] = {uint8_t(value), uint8_t(value >> 8)};
        if (j_.shiftIR(bytes, nullptr, 10) < 0) throw std::runtime_error("IR scan failed");
    }
    uint64_t dr_word(uint64_t value, unsigned bits) {
        uint8_t tx[8] = {}, rx[8] = {};
        for (unsigned i = 0; i < 8; i++) tx[i] = uint8_t(value >> (8 * i));
        if (j_.shiftDR(tx, rx, int(bits)) < 0) throw std::runtime_error("DR scan failed");
        uint64_t r = 0;
        for (unsigned i = 0; i < 8; i++) r |= uint64_t(rx[i]) << (8 * i);
        return r;
    }
    uint32_t info() {
        uint32_t result = 0;
        for (unsigned i = 0; i < 8; i++) result |= uint32_t(dr_word(0, 4) & 15) << (4 * i);
        return result;
    }
    void select(unsigned ir) {
        if (ir == ir_) return;
        instruction(0x00e); dr_word((uint64_t(1) << m_) | ir, m_ + 1);
        instruction(0x00c);
        ir_ = ir;
    }
    jtag_pins_conf_t pins_;
    Jtag j_;
    unsigned m_ = 0, block_ = 0, ir_ = 99;
};

// word index -> value, contiguous runs
using Image = std::map<uint64_t, std::vector<uint64_t>>;

Image read_image(const std::string &path) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("cannot open " + path);
    Image img;
    std::map<uint64_t, uint64_t> words;
    std::string line;
    uint64_t addr = 0;
    bool have_addr = false;
    while (std::getline(f, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
        if (line.empty()) continue;
        if (line[0] == '@') {
            addr = std::stoull(line.substr(1), nullptr, 16);
            have_addr = true;
            continue;
        }
        if (!have_addr || line.size() != 16 || line.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos)
            throw std::runtime_error("unsupported hex line: " + line);
        if (!words.emplace(addr, std::stoull(line, nullptr, 16)).second)
            throw std::runtime_error("image word written twice");
        addr++;
    }
    for (auto &[a, v] : words) {
        if (!img.empty()) {
            auto &last = *img.rbegin();
            if (last.first + last.second.size() == a) { last.second.push_back(v); continue; }
        }
        img[a] = {v};
    }
    return img;
}

size_t image_words(const Image &img) {
    size_t n = 0;
    for (auto &r : img) n += r.second.size();
    return n;
}

void check(const Status &s, unsigned expected_count, const char *what) {
    if (s.error() || s.count() != expected_count || s.fault() || s.memory_fault()) {
        char msg[160];
        std::snprintf(msg, sizeof msg, "%s failed: status %016llx", what, (unsigned long long)s.raw);
        throw std::runtime_error(msg);
    }
}

void write_image(Mailbox &mb, const Image &img) {
    size_t done = 0, total = image_words(img);
    for (auto &[base, words] : img)
        for (size_t i = 0; i < words.size(); i += mb.block()) {
            size_t n = std::min<size_t>(mb.block(), words.size() - i);
            mb.put(std::vector<uint64_t>(words.begin() + i, words.begin() + i + n));
            check(mb.command(OP_WRITE, unsigned(n), base + i, 5), unsigned(n), "write");
            done += n;
            std::fprintf(stderr, "\rwrite %zu/%zu words", done, total);
        }
    std::fprintf(stderr, "\n");
}

void verify_image(Mailbox &mb, const Image &img) {
    size_t done = 0, total = image_words(img);
    for (auto &[base, words] : img)
        for (size_t i = 0; i < words.size(); i += mb.block()) {
            size_t n = std::min<size_t>(mb.block(), words.size() - i);
            check(mb.command(OP_READ, unsigned(n), base + i, 5), unsigned(n), "read");
            auto back = mb.get(n);
            for (size_t k = 0; k < n; k++)
                if (back[k] != words[i + k]) {
                    char msg[160];
                    std::snprintf(msg, sizeof msg, "verify mismatch at byte offset 0x%llx: %016llx != %016llx",
                                  (unsigned long long)((base + i + k) * 8), (unsigned long long)back[k],
                                  (unsigned long long)words[i + k]);
                    throw std::runtime_error(msg);
                }
            done += n;
            std::fprintf(stderr, "\rverify %zu/%zu words", done, total);
        }
    std::fprintf(stderr, "\n");
}
} // namespace

int main(int argc, char **argv) {
    try {
        std::string mode = argc >= 2 ? argv[1] : "";
        if (!(mode == "status" && argc == 2) &&
            !((mode == "load" || mode == "verify" || mode == "release") && argc == 3)) {
            std::fprintf(stderr, "usage: %s status | load IMAGE.hex | verify IMAGE.hex | release IMAGE.hex\n", argv[0]);
            return 64;
        }
        Mailbox mb;
        Status s = mb.status();
        if (mode == "status") {
            std::printf("{\"status\":\"%016llx\",\"cleared\":%d,\"cpu_run\":%d,\"fault\":%d,\"memory_fault\":%d,\"block_words\":%u}\n",
                        (unsigned long long)s.raw, s.cleared(), s.run(), s.fault(), s.memory_fault(), mb.block());
            return 0;
        }
        if (s.run()) throw std::runtime_error("CPU already released; reprogram the FPGA to load again");
        Image img = read_image(argv[2]);
        if (img.empty()) throw std::runtime_error("empty image");
        auto t0 = std::chrono::steady_clock::now();
        if (mode == "load") {
            std::fprintf(stderr, "clear all RAM\n");
            check(mb.command(OP_CLEAR, 0, 0, 120), 1, "clear");
            write_image(mb, img);
        } else if (!s.cleared()) {
            throw std::runtime_error("RAM not cleared/loaded");
        }
        verify_image(mb, img);
        if (mode == "release") {
            mb.put({RUN_WORD});
            Status r = mb.command(OP_RELEASE, 0, 0, 5);
            check(r, 1, "release");
            if (!r.run()) throw std::runtime_error("CPU not released");
            std::fprintf(stderr, "CPU released\n");
        }
        double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::printf("{\"mode\":\"%s\",\"words\":%zu,\"seconds\":%.1f}\n", mode.c_str(), image_words(img), t);
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "\nde0cv-jtag-load: %s\n", e.what());
        return 1;
    }
}
